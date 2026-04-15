#include "molfile_plugin.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

struct ElementInfo {
  const char *symbol;
  int atomic_number;
  float mass;
  float radius;
};

static const ElementInfo kElements[] = {
  {"H", 1, 1.00794f, 1.20f},   {"He", 2, 4.00260f, 1.40f},
  {"Li", 3, 6.94100f, 1.82f},  {"Be", 4, 9.01218f, 2.00f},
  {"B", 5, 10.8110f, 2.00f},   {"C", 6, 12.0107f, 1.70f},
  {"N", 7, 14.0067f, 1.55f},   {"O", 8, 15.9994f, 1.52f},
  {"F", 9, 18.9984f, 1.47f},   {"Ne", 10, 20.1797f, 1.54f},
  {"Na", 11, 22.9898f, 1.36f}, {"Mg", 12, 24.3050f, 1.18f},
  {"Al", 13, 26.9815f, 2.00f}, {"Si", 14, 28.0855f, 2.10f},
  {"P", 15, 30.9738f, 1.80f},  {"S", 16, 32.0650f, 1.80f},
  {"Cl", 17, 35.4530f, 2.27f}, {"Ar", 18, 39.9480f, 1.88f},
  {"K", 19, 39.0983f, 1.76f},  {"Ca", 20, 40.0780f, 1.37f},
  {"Br", 35, 79.9040f, 1.85f}, {"I", 53, 126.904f, 1.98f}
};

struct AtomRecord {
  std::string raw_symbol;
  std::string element;
  float x = 0.0f;
  float y = 0.0f;
  float z = 0.0f;
  float charge = 0.0f;
};

struct BondRecord {
  int from = 0;   // zero-based
  int to = 0;     // zero-based
  float order = 1.0f;
};

struct Record {
  std::string name;
  std::vector<AtomRecord> atoms;
  std::vector<BondRecord> bonds;
};

struct SDFData {
  std::string filepath;
  std::vector<Record> records;
  std::vector<size_t> timestep_record_indices;
  size_t next_timestep = 0;

  int *bond_from = nullptr;
  int *bond_to = nullptr;
  float *bond_order = nullptr;
};

static molfile_plugin_t plugin;

static std::string trim(const std::string &value) {
  size_t start = 0;
  while (start < value.size() &&
         std::isspace(static_cast<unsigned char>(value[start]))) {
    ++start;
  }

  size_t end = value.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    --end;
  }

  return value.substr(start, end - start);
}

static std::string to_upper(std::string value) {
  for (char &ch : value) {
    ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
  }
  return value;
}

static std::vector<std::string> split_lines(const std::string &text) {
  std::vector<std::string> lines;
  std::string current;
  for (size_t i = 0; i < text.size(); ++i) {
    const char ch = text[i];
    if (ch == '\r') {
      if (i + 1 < text.size() && text[i + 1] == '\n') {
        ++i;
      }
      lines.push_back(current);
      current.clear();
    } else if (ch == '\n') {
      lines.push_back(current);
      current.clear();
    } else {
      current.push_back(ch);
    }
  }
  lines.push_back(current);
  return lines;
}

static std::vector<std::string> split_tokens(const std::string &line) {
  std::istringstream in(line);
  std::vector<std::string> tokens;
  std::string token;
  while (in >> token) {
    tokens.push_back(token);
  }
  return tokens;
}

static bool parse_int(const std::string &value, int &out) {
  char *end = nullptr;
  long result = std::strtol(value.c_str(), &end, 10);
  if (end == value.c_str() || *end != '\0') {
    return false;
  }
  out = static_cast<int>(result);
  return true;
}

static bool parse_float(const std::string &value, float &out) {
  char *end = nullptr;
  float result = std::strtof(value.c_str(), &end);
  if (end == value.c_str() || *end != '\0') {
    return false;
  }
  out = result;
  return true;
}

static bool parse_fixed_int(const std::string &line, size_t start, size_t end,
                            int &value) {
  if (start >= line.size()) {
    value = 0;
    return true;
  }
  end = std::min(end, line.size() - 1);
  return parse_int(trim(line.substr(start, end - start + 1)), value);
}

static bool parse_fixed_float(const std::string &line, size_t start, size_t end,
                              float &value) {
  if (start >= line.size()) {
    value = 0.0f;
    return true;
  }
  end = std::min(end, line.size() - 1);
  const std::string field = trim(line.substr(start, end - start + 1));
  if (field.empty()) {
    value = 0.0f;
    return true;
  }
  return parse_float(field, value);
}

static const ElementInfo *lookup_element(const std::string &symbol) {
  const std::string upper = to_upper(symbol);
  for (const auto &entry : kElements) {
    if (to_upper(entry.symbol) == upper) {
      return &entry;
    }
  }
  return nullptr;
}

static std::string canonicalize_element(const std::string &raw_symbol) {
  const std::string token = trim(raw_symbol);
  if (token.empty()) {
    return "X";
  }

  const std::string upper = to_upper(token);
  if (upper == "D" || upper == "T") return "H";
  if (upper == "*" || upper == "A" || upper == "Q" || upper == "L" ||
      upper == "LP" || upper == "R" || upper == "R#") {
    return "X";
  }

  if (const ElementInfo *info = lookup_element(token)) {
    return info->symbol;
  }

  return "X";
}

static float charge_from_v2000_code(int code) {
  switch (code) {
    case 1: return 3.0f;
    case 2: return 2.0f;
    case 3: return 1.0f;
    case 5: return -1.0f;
    case 6: return -2.0f;
    case 7: return -3.0f;
    default: return 0.0f;
  }
}

static float bond_order_from_code(int code) {
  switch (code) {
    case 1: return 1.0f;
    case 2: return 2.0f;
    case 3: return 3.0f;
    case 4: return 1.5f;
    case 6: return 1.5f;
    case 7: return 1.5f;
    default: return 1.0f;
  }
}

static std::string sanitize_resname(const std::string &name) {
  std::string out;
  for (char ch : name) {
    if (std::isalnum(static_cast<unsigned char>(ch))) {
      out.push_back(static_cast<char>(
          std::toupper(static_cast<unsigned char>(ch))));
    }
    if (out.size() == 7) break;
  }
  if (out.empty()) out = "MOL";
  return out;
}

static bool parse_property_name(const std::vector<std::string> &lines, size_t start,
                                std::string &name) {
  for (size_t idx = start; idx < lines.size(); ++idx) {
    const std::string line = lines[idx];
    if (!(line.rfind("> <", 0) == 0 || line.rfind(">  <", 0) == 0)) {
      continue;
    }

    const size_t left = line.find('<');
    const size_t right = line.find('>', left + 1);
    if (left == std::string::npos || right == std::string::npos) continue;

    const std::string key = to_upper(trim(line.substr(left + 1, right - left - 1)));
    if (key != "NAME" && key != "TITLE" && key != "ID") continue;

    if (idx + 1 < lines.size()) {
      const std::string value = trim(lines[idx + 1]);
      if (!value.empty()) {
        name = value;
        return true;
      }
    }
  }
  return false;
}

static bool parse_v2000_record(const std::vector<std::string> &lines, Record &record,
                               std::string &error) {
  if (lines.size() < 4) {
    error = "record too short";
    return false;
  }

  int natoms = 0;
  int nbonds = 0;
  if (!parse_fixed_int(lines[3], 0, 2, natoms) ||
      !parse_fixed_int(lines[3], 3, 5, nbonds)) {
    error = "invalid counts line";
    return false;
  }

  if (lines.size() < static_cast<size_t>(4 + natoms + nbonds)) {
    error = "record ended before atom/bond blocks were complete";
    return false;
  }

  record.name = trim(lines[0]);
  record.atoms.clear();
  record.bonds.clear();
  record.atoms.reserve(static_cast<size_t>(natoms));
  record.bonds.reserve(static_cast<size_t>(nbonds));

  for (int i = 0; i < natoms; ++i) {
    const std::string &line = lines[4 + i];
    AtomRecord atom;
    int charge_code = 0;
    if (!parse_fixed_float(line, 0, 9, atom.x) ||
        !parse_fixed_float(line, 10, 19, atom.y) ||
        !parse_fixed_float(line, 20, 29, atom.z) ||
        !parse_fixed_int(line, 36, 38, charge_code)) {
      error = "invalid atom record";
      return false;
    }
    atom.raw_symbol = trim(line.size() > 34 ? line.substr(31, 3) : "");
    atom.element = canonicalize_element(atom.raw_symbol);
    if (atom.raw_symbol.empty()) atom.raw_symbol = atom.element;
    atom.charge = charge_from_v2000_code(charge_code);
    record.atoms.push_back(atom);
  }

  for (int i = 0; i < nbonds; ++i) {
    const std::string &line = lines[4 + natoms + i];
    int from = 0, to = 0, code = 0;
    if (!parse_fixed_int(line, 0, 2, from) ||
        !parse_fixed_int(line, 3, 5, to) ||
        !parse_fixed_int(line, 6, 8, code)) {
      error = "invalid bond record";
      return false;
    }
    if (from <= 0 || to <= 0) {
      error = "invalid bond atom index";
      return false;
    }
    BondRecord bond;
    bond.from = from - 1;
    bond.to = to - 1;
    bond.order = bond_order_from_code(code);
    record.bonds.push_back(bond);
  }

  size_t idx = static_cast<size_t>(4 + natoms + nbonds);
  for (; idx < lines.size(); ++idx) {
    if (lines[idx] == "M  END") {
      ++idx;
      break;
    }

    const std::vector<std::string> tokens = split_tokens(lines[idx]);
    if (tokens.size() >= 3 && tokens[0] == "M" && tokens[1] == "CHG") {
      int count = 0;
      if (!parse_int(tokens[2], count)) continue;
      for (int i = 0; i < count; ++i) {
        const size_t atom_pos = 3 + static_cast<size_t>(2 * i);
        const size_t charge_pos = atom_pos + 1;
        if (charge_pos >= tokens.size()) break;
        int atom_index = 0;
        int charge = 0;
        if (!parse_int(tokens[atom_pos], atom_index) ||
            !parse_int(tokens[charge_pos], charge)) {
          continue;
        }
        if (atom_index > 0 &&
            atom_index <= static_cast<int>(record.atoms.size())) {
          record.atoms[static_cast<size_t>(atom_index - 1)].charge =
              static_cast<float>(charge);
        }
      }
    }
  }

  if (record.name.empty()) {
    parse_property_name(lines, idx, record.name);
  }
  return true;
}

static bool next_v3000_line(const std::vector<std::string> &lines, size_t &idx,
                            std::string &logical) {
  logical.clear();
  while (idx < lines.size()) {
    std::string line = lines[idx++];
    if (line.empty()) continue;
    if (line.rfind("M  V30 ", 0) != 0) {
      logical = line;
      return true;
    }

    std::string content = line.substr(7);
    if (!content.empty() && content.back() == '-') {
      content.pop_back();
      logical += content;
      continue;
    }

    logical += content;
    return true;
  }
  return false;
}

static bool parse_v3000_record(const std::vector<std::string> &lines, Record &record,
                               std::string &error) {
  if (lines.size() < 4) {
    error = "record too short";
    return false;
  }

  record.name = trim(lines[0]);
  record.atoms.clear();
  record.bonds.clear();

  size_t idx = 4;
  std::string logical;

  while (next_v3000_line(lines, idx, logical)) {
    if (logical == "BEGIN CTAB") break;
  }
  if (logical != "BEGIN CTAB") {
    error = "missing BEGIN CTAB";
    return false;
  }

  if (!next_v3000_line(lines, idx, logical) || logical.rfind("COUNTS ", 0) != 0) {
    error = "missing COUNTS line";
    return false;
  }
  const std::vector<std::string> count_tokens = split_tokens(logical);
  if (count_tokens.size() < 3) {
    error = "invalid COUNTS line";
    return false;
  }
  int natoms = 0;
  int nbonds = 0;
  if (!parse_int(count_tokens[1], natoms) || !parse_int(count_tokens[2], nbonds)) {
    error = "invalid COUNTS values";
    return false;
  }
  record.atoms.reserve(static_cast<size_t>(natoms));
  record.bonds.reserve(static_cast<size_t>(nbonds));

  while (next_v3000_line(lines, idx, logical)) {
    if (logical == "BEGIN ATOM") break;
  }
  if (logical != "BEGIN ATOM") {
    error = "missing BEGIN ATOM";
    return false;
  }

  while (next_v3000_line(lines, idx, logical)) {
    if (logical == "END ATOM") break;
    const std::vector<std::string> tokens = split_tokens(logical);
    if (tokens.size() < 6) {
      error = "invalid V3000 atom line";
      return false;
    }
    AtomRecord atom;
    atom.raw_symbol = tokens[1];
    atom.element = canonicalize_element(atom.raw_symbol);
    if (!parse_float(tokens[2], atom.x) ||
        !parse_float(tokens[3], atom.y) ||
        !parse_float(tokens[4], atom.z)) {
      error = "invalid V3000 coordinates";
      return false;
    }
    for (size_t i = 6; i < tokens.size(); ++i) {
      if (tokens[i].rfind("CHG=", 0) == 0) {
        int charge = 0;
        if (parse_int(tokens[i].substr(4), charge)) {
          atom.charge = static_cast<float>(charge);
        }
      }
    }
    record.atoms.push_back(atom);
  }

  while (next_v3000_line(lines, idx, logical)) {
    if (logical == "BEGIN BOND") break;
  }
  if (logical != "BEGIN BOND") {
    error = "missing BEGIN BOND";
    return false;
  }

  while (next_v3000_line(lines, idx, logical)) {
    if (logical == "END BOND") break;
    const std::vector<std::string> tokens = split_tokens(logical);
    if (tokens.size() < 4) {
      error = "invalid V3000 bond line";
      return false;
    }
    int code = 0, from = 0, to = 0;
    if (!parse_int(tokens[1], code) ||
        !parse_int(tokens[2], from) ||
        !parse_int(tokens[3], to)) {
      error = "invalid V3000 bond values";
      return false;
    }
    BondRecord bond;
    bond.from = from - 1;
    bond.to = to - 1;
    bond.order = bond_order_from_code(code);
    record.bonds.push_back(bond);
  }

  if (record.name.empty()) {
    parse_property_name(lines, idx, record.name);
  }
  return true;
}

static bool parse_record(const std::vector<std::string> &lines, Record &record,
                         std::string &error) {
  if (lines.size() < 4) {
    error = "record too short";
    return false;
  }

  const std::string version_line = lines[3];
  if (version_line.find("V3000") != std::string::npos) {
    return parse_v3000_record(lines, record, error);
  }
  return parse_v2000_record(lines, record, error);
}

static bool has_content(const std::vector<std::string> &lines) {
  for (const auto &line : lines) {
    if (!trim(line).empty()) return true;
  }
  return false;
}

static bool load_sdf_file(const std::string &filepath, std::vector<Record> &records,
                          std::string &error) {
  std::ifstream in(filepath, std::ios::binary);
  if (!in) {
    error = "unable to open file";
    return false;
  }

  std::ostringstream buffer;
  buffer << in.rdbuf();
  const std::vector<std::string> lines = split_lines(buffer.str());

  std::vector<std::string> current;
  records.clear();
  for (const auto &line : lines) {
    if (line == "$$$$") {
      if (has_content(current)) {
        Record record;
        if (!parse_record(current, record, error)) {
          return false;
        }
        records.push_back(std::move(record));
      }
      current.clear();
      continue;
    }
    current.push_back(line);
  }

  if (has_content(current)) {
    Record record;
    if (!parse_record(current, record, error)) {
      return false;
    }
    records.push_back(std::move(record));
  }

  if (records.empty()) {
    error = "no SDF records found";
    return false;
  }
  return true;
}

static void copy_string(char *dest, size_t size, const std::string &value) {
  if (size == 0) return;
  std::snprintf(dest, size, "%s", value.c_str());
}

static void *open_file_read(const char *filepath, const char * /*filetype*/,
                            int *natoms) {
  auto *data = new SDFData;
  data->filepath = filepath ? filepath : "";

  std::string error;
  if (!load_sdf_file(data->filepath, data->records, error)) {
    std::fprintf(stderr, "sdfplugin) %s: %s\n", error.c_str(), data->filepath.c_str());
    delete data;
    return nullptr;
  }

  const size_t first_natoms = data->records.front().atoms.size();
  if (first_natoms == 0) {
    std::fprintf(stderr, "sdfplugin) first record has no atoms: %s\n",
                 data->filepath.c_str());
    delete data;
    return nullptr;
  }

  for (size_t i = 0; i < data->records.size(); ++i) {
    if (data->records[i].atoms.size() == first_natoms) {
      data->timestep_record_indices.push_back(i);
    }
  }

  if (data->timestep_record_indices.size() != data->records.size()) {
    std::fprintf(stderr,
                 "sdfplugin) warning: only %zu/%zu records have %zu atoms; "
                 "variable-size records will be ignored as extra frames.\n",
                 data->timestep_record_indices.size(), data->records.size(),
                 first_natoms);
  }

  *natoms = static_cast<int>(first_natoms);
  return data;
}

static int read_structure(void *v, int *optflags, molfile_atom_t *atoms) {
  auto *data = static_cast<SDFData *>(v);
  if (!data || data->records.empty()) return MOLFILE_ERROR;

  const Record &record = data->records.front();
  const std::string resname = sanitize_resname(record.name);
  std::unordered_map<std::string, int> counts;

  for (size_t i = 0; i < record.atoms.size(); ++i) {
    const AtomRecord &src = record.atoms[i];
    molfile_atom_t &dst = atoms[i];
    std::memset(&dst, 0, sizeof(molfile_atom_t));

    const std::string element = src.element;
    const std::string prefix =
        (element != "X" && !element.empty()) ? element : to_upper(src.raw_symbol);
    const int serial = ++counts[prefix];
    const std::string atom_name = prefix + std::to_string(serial);

    copy_string(dst.name, sizeof(dst.name), atom_name);
    copy_string(dst.type, sizeof(dst.type),
                src.raw_symbol.empty() ? src.element : src.raw_symbol);
    copy_string(dst.resname, sizeof(dst.resname), resname);
    copy_string(dst.segid, sizeof(dst.segid), "SDF");
    copy_string(dst.chain, sizeof(dst.chain), "A");
    dst.resid = 1;
    dst.charge = src.charge;

    const ElementInfo *info = lookup_element(src.element);
    if (info) {
      dst.atomicnumber = info->atomic_number;
      dst.mass = info->mass;
      dst.radius = info->radius;
    } else {
      dst.atomicnumber = 0;
      dst.mass = 0.0f;
      dst.radius = 2.0f;
    }
  }

  *optflags = MOLFILE_CHARGE | MOLFILE_MASS | MOLFILE_RADIUS | MOLFILE_ATOMICNUMBER;
  return MOLFILE_SUCCESS;
}

static int read_bonds(void *v, int *nbonds, int **from, int **to,
                      float **bondorder, int **bondtype, int *nbondtypes,
                      char ***bondtypename) {
  auto *data = static_cast<SDFData *>(v);
  if (!data || data->records.empty()) return MOLFILE_ERROR;

  const Record &record = data->records.front();
  *nbonds = static_cast<int>(record.bonds.size());

  if (*nbonds == 0) {
    *from = nullptr;
    *to = nullptr;
    *bondorder = nullptr;
    *bondtype = nullptr;
    *nbondtypes = 0;
    *bondtypename = nullptr;
    return MOLFILE_SUCCESS;
  }

  data->bond_from = static_cast<int *>(std::malloc(sizeof(int) * static_cast<size_t>(*nbonds)));
  data->bond_to = static_cast<int *>(std::malloc(sizeof(int) * static_cast<size_t>(*nbonds)));
  data->bond_order = static_cast<float *>(std::malloc(sizeof(float) * static_cast<size_t>(*nbonds)));
  if (!data->bond_from || !data->bond_to || !data->bond_order) {
    return MOLFILE_ERROR;
  }

  for (int i = 0; i < *nbonds; ++i) {
    data->bond_from[i] = record.bonds[static_cast<size_t>(i)].from + 1;
    data->bond_to[i] = record.bonds[static_cast<size_t>(i)].to + 1;
    data->bond_order[i] = record.bonds[static_cast<size_t>(i)].order;
  }

  *from = data->bond_from;
  *to = data->bond_to;
  *bondorder = data->bond_order;
  *bondtype = nullptr;
  *nbondtypes = 0;
  *bondtypename = nullptr;
  return MOLFILE_SUCCESS;
}

static int read_next_timestep(void *v, int natoms, molfile_timestep_t *ts) {
  auto *data = static_cast<SDFData *>(v);
  if (!data) return MOLFILE_ERROR;
  if (data->next_timestep >= data->timestep_record_indices.size()) {
    return MOLFILE_EOF;
  }

  const Record &record =
      data->records[data->timestep_record_indices[data->next_timestep++]];
  if (static_cast<int>(record.atoms.size()) != natoms) {
    return MOLFILE_EOF;
  }

  if (ts && ts->coords) {
    for (int i = 0; i < natoms; ++i) {
      const AtomRecord &atom = record.atoms[static_cast<size_t>(i)];
      ts->coords[3 * i + 0] = atom.x;
      ts->coords[3 * i + 1] = atom.y;
      ts->coords[3 * i + 2] = atom.z;
    }
  }
  return MOLFILE_SUCCESS;
}

static void close_file_read(void *v) {
  auto *data = static_cast<SDFData *>(v);
  if (!data) return;
  std::free(data->bond_from);
  std::free(data->bond_to);
  std::free(data->bond_order);
  delete data;
}

static void init_plugin() {
  std::memset(&plugin, 0, sizeof(plugin));
  plugin.abiversion = vmdplugin_ABIVERSION;
  plugin.type = MOLFILE_PLUGIN_TYPE;
  plugin.name = "SDF";
  plugin.prettyname = "Structure Data File";
  plugin.author = "OpenAI";
  plugin.majorv = 0;
  plugin.minorv = 1;
  plugin.is_reentrant = VMDPLUGIN_THREADSAFE;
  plugin.filename_extension = "sdf,sd";
  plugin.open_file_read = open_file_read;
  plugin.read_structure = read_structure;
  plugin.read_bonds = read_bonds;
  plugin.read_next_timestep = read_next_timestep;
  plugin.close_file_read = close_file_read;
}

}  // namespace

VMDPLUGIN_EXTERN int VMDPLUGIN_init() {
  init_plugin();
  return VMDPLUGIN_SUCCESS;
}

VMDPLUGIN_EXTERN int VMDPLUGIN_register(void *v, vmdplugin_register_cb cb) {
  return (*cb)(v, reinterpret_cast<vmdplugin_t *>(&plugin));
}

VMDPLUGIN_EXTERN int VMDPLUGIN_fini() {
  return VMDPLUGIN_SUCCESS;
}
