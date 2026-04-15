#!/bin/sh

# Compatibility wrapper for VMD's legacy Babel molfile plugin.
# VMD 1.9.4 calls Babel with Open Babel 2 style arguments:
#   babel -i<fmt> <input> all -o<fmt> <output>
# Homebrew ships Open Babel 3 as `obabel`, which expects:
#   obabel -i<fmt> <input> -O <output>

OBABEL_BIN="${OBABEL_BIN:-/opt/homebrew/bin/obabel}"

if [ ! -x "$OBABEL_BIN" ]; then
  echo "babel_compat.sh: cannot execute obabel at $OBABEL_BIN" >&2
  exit 127
fi

set -- "$@"

out_file=""
out_flag=""
translated_args=""

append_arg() {
  if [ -z "$translated_args" ]; then
    translated_args=$(printf '%s' "$1")
  else
    translated_args=$(printf '%s\n%s' "$translated_args" "$1")
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    all)
      shift
      ;;
    -o*)
      if [ "$#" -lt 2 ]; then
        echo "babel_compat.sh: missing output file after $1" >&2
        exit 2
      fi
      out_flag=$1
      out_file=$2
      shift 2
      ;;
    *)
      append_arg "$1"
      shift
      ;;
  esac
done

if [ -z "$out_file" ]; then
  echo "babel_compat.sh: no output file provided" >&2
  exit 2
fi

if [ -z "$out_flag" ]; then
  echo "babel_compat.sh: no output format provided" >&2
  exit 2
fi

set -f
IFS='
'
set -- $translated_args
unset IFS
set +f

exec "$OBABEL_BIN" "$@" "$out_flag" -O "$out_file"
