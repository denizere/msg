#!/bin/sh

echo "The following tools/versions will be used:"
echo "Perl:"
perl --version | head -n 2
echo "Python:"
python -V
echo "R:"
R --version | grep version
echo "BWA:"
bwa 2>&1 >/dev/null | grep Version
echo "Samtools:"
samtools 2>&1 >/dev/null | grep Version

