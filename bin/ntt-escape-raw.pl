#!/usr/bin/env perl
# Author: PB and Claude
# Date: 2025-10-11
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt-escape-raw.pl
#
# Field-aware escaping for NTT loader
# Escapes special characters only in the path field (7th field)
# Keeps field delimiters (byte 034) unescaped

use strict;
use warnings;

binmode STDIN;
binmode STDOUT;

my $record_sep = "\0";  # Null byte
my $field_sep = "\034"; # Byte 034

local $/ = $record_sep;  # Read records

while (my $record = <STDIN>) {
    chomp($record);  # Remove null terminator

    my @fields = split(/\Q$field_sep\E/, $record, 7);  # Split into max 7 fields

    if (@fields == 7) {
        # Escape special characters in the path field (7th field)
        $fields[6] =~ s/\\/\\\\/g;        # Backslash → \\
        $fields[6] =~ s/\034/\\\034/g;    # Byte 034 → \<034>
        $fields[6] =~ s/\r/\\015/g;       # CR → \015
        $fields[6] =~ s/\n/\\012/g;       # LF → \012
    }

    # Rejoin with unescaped field separators
    print join($field_sep, @fields);
    print "\n";  # Newline as record separator for PostgreSQL
}
