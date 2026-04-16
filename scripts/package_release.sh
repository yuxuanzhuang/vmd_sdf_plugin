#!/usr/bin/env bash
set -euo pipefail

version="${1:-dev}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uname_s="$(uname -s)"
arch_name="$(uname -m)"
dist_dir="${repo_root}/dist"
plugin_ext="so"
archive_ext="tar.gz"

case "${uname_s}" in
  Darwin)
    os_name="darwin"
    ;;
  Linux)
    os_name="linux"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    os_name="windows"
    plugin_ext="dll"
    archive_ext="zip"
    ;;
  *)
    os_name="$(printf '%s' "${uname_s}" | tr '[:upper:]' '[:lower:]')"
    ;;
esac

package_name="vmd-sdf-plugin-${version}-${os_name}-${arch_name}"
stage_dir="${dist_dir}/${package_name}"
archive_path="${dist_dir}/${package_name}.${archive_ext}"
plugin_path="${repo_root}/molfile/sdfplugin.${plugin_ext}"

rm -rf "${stage_dir}" "${archive_path}"
mkdir -p "${stage_dir}/molfile"

cp "${repo_root}/README.md" "${stage_dir}/"
cp "${repo_root}/LICENSE" "${stage_dir}/"
cp "${repo_root}/THIRD_PARTY_NOTICES.md" "${stage_dir}/"
cp "${plugin_path}" "${stage_dir}/molfile/"
cp -R "${repo_root}/sdfloader1.0" "${stage_dir}/"
cp -R "${repo_root}/examples" "${stage_dir}/"
cp -R "${repo_root}/LICENSES" "${stage_dir}/"

if [[ "${archive_ext}" == "zip" ]]; then
  (
    cd "${dist_dir}"
    zip -qr "${archive_path}" "${package_name}"
  )
else
  tar -czf "${archive_path}" -C "${dist_dir}" "${package_name}"
fi

printf '%s\n' "${archive_path}"
