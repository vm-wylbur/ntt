#!/usr/bin/env python3
# Author: PB and Claude
# Date: 2025-11-16
# License: (c) HRDAG, 2025, GPL-2 or newer
#
# ------
# ntt/bin/ntt_db.py
#
# Shared database connection utility for NTT tools
#

import os
import psycopg
from psycopg.rows import dict_row


def get_db_connection(row_factory=dict_row):
    """
    Get PostgreSQL database connection.

    When running as root (via sudo), connects as the SUDO_USER to avoid
    PostgreSQL "role root does not exist" error.

    Args:
        row_factory: Row factory for result rows (default: dict_row)

    Returns:
        psycopg.Connection instance

    Environment variables:
        NTT_DB_URL: PostgreSQL connection string (default: postgres:///copyjob)
        SUDO_USER: Original user when running with sudo
    """
    db_url = os.environ.get('NTT_DB_URL', 'postgres:///copyjob')

    # When running as root (sudo), connect via TCP as SUDO_USER
    # This avoids "peer authentication failed" with Unix sockets
    # Requires pg_hba.conf: host all all 127.0.0.1/32 trust
    if os.geteuid() == 0 and 'SUDO_USER' in os.environ:
        sudo_user = os.environ['SUDO_USER']
        # Convert postgres:///dbname to postgres://user@localhost/dbname
        # This forces TCP connection instead of Unix socket
        if db_url.startswith('postgres:///'):
            dbname = db_url.replace('postgres:///', '')
            db_url = f"postgres://{sudo_user}@localhost/{dbname}"
        else:
            # If URL already has host, just add user
            if '?' in db_url:
                db_url = f"{db_url}&user={sudo_user}"
            else:
                db_url = f"{db_url}?user={sudo_user}"

    conn = psycopg.connect(db_url, row_factory=row_factory)
    return conn
