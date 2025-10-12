#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-10-11
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_db.py
#
# NTT Database Connection Utilities
# Standard PostgreSQL connection with sudo user handling

import os
import psycopg
from psycopg.rows import dict_row


def get_db_connection(row_factory=dict_row):
    """
    Standard NTT database connection with sudo user handling.

    Handles:
    - Environment variable fallbacks (NTT_DB_URL)
    - SUDO_USER detection for PGUSER
    - DB URL fixup for sudo contexts

    Args:
        row_factory: psycopg row factory (default: dict_row)

    Returns:
        psycopg.Connection with configured row factory
    """
    db_url = os.environ.get('NTT_DB_URL', 'postgresql:///copyjob')

    # Set PostgreSQL user for sudo contexts
    if 'SUDO_USER' in os.environ:
        os.environ['PGUSER'] = os.environ['SUDO_USER']
    elif os.geteuid() == 0 and 'USER' in os.environ:
        os.environ['PGUSER'] = 'postgres'

    # Fix DB_URL for sudo (add username if not present)
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        if '://' in db_url and '@' not in db_url:
            db_url = db_url.replace(':///', f"://{os.environ['SUDO_USER']}@localhost/")

    return psycopg.connect(db_url, row_factory=row_factory)
