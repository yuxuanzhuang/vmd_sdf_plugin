#!/usr/bin/env bash
set -euo pipefail

version="${1:-dev}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
os_name="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch_name="$(uname -m)"
package_name="vmd-sdf-plugin-${version}-${os_name}-${arch_name}"
dist_dir="${repo_root}/dist"
stage_dir="${dist_dir}/${package_name}"
archive_path="${dist_dir}/${package_name}.tar.gz"

rm -rf "${stage_dir}" "${archive_path}"
mkdir -p "${stage_dir}/molfile"

cp "${repo_root}/README.md" "${stage_dir}/"
cp "${repo_root}/molfile/sdfplugin.so" "${stage_dir}/molfile/"
cp -R "${repo_root}/sdfloader1.0" "${stage_dir}/"
cp -R "${repo_root}/examples" "${stage_dir}/"

tar -czf "${archive_path}" -C "${dist_dir}" "${package_name}"
printf '%s\n' "${archive_path}"
