"""
E2E Validator Logging Module
=============================

Provides LOG_LEVEL-aware logging functions that match shell script patterns.
"""

import os
import sys

# ============================================================================
# Logging Configuration (matches shell script LOG_LEVEL pattern)
# ============================================================================
#
# LOG_LEVEL environment variable controls output verbosity:
#   DEBUG - Show everything (most verbose, default for CI/CD troubleshooting)
#   INFO  - Show info, success, warnings, and errors
#   WARN  - Show success, warnings, and errors (clean output)
#   ERROR - Only show errors (quietest)
#
# Default: DEBUG (for CI/CD troubleshooting - helps triage issues quickly)
#
# Usage:
#   LOG_LEVEL=DEBUG python -m e2e_validator ...  # Show everything
#   LOG_LEVEL=WARN python -m e2e_validator ...   # Clean output
#   LOG_LEVEL=ERROR python -m e2e_validator ...  # Errors only
#
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'DEBUG').upper()

# Log level hierarchy (from most to least verbose)
_LOG_LEVELS = {'DEBUG': 0, 'INFO': 1, 'WARN': 2, 'ERROR': 3}
_CURRENT_LEVEL = _LOG_LEVELS.get(LOG_LEVEL, 0)  # Default to DEBUG if invalid

def should_log(level: str) -> bool:
    """Check if a message at given level should be logged."""
    return _LOG_LEVELS.get(level, 0) >= _CURRENT_LEVEL

# Explicit log functions (aligned with shell script pattern)
def log_debug(*args, **kwargs):
    """Print debug messages (only if LOG_LEVEL=DEBUG)."""
    if should_log('DEBUG'):
        print(*args, **kwargs)

def log_info(*args, **kwargs):
    """Print info messages (if LOG_LEVEL is INFO or DEBUG)."""
    if should_log('INFO'):
        print(*args, **kwargs)

def log_success(*args, **kwargs):
    """Print success messages (if LOG_LEVEL is WARN, INFO, or DEBUG)."""
    if should_log('WARN'):
        print(*args, **kwargs)

def log_warning(*args, **kwargs):
    """Print warning messages (if LOG_LEVEL is WARN, INFO, or DEBUG)."""
    if should_log('WARN'):
        print(*args, **kwargs)

def log_error(*args, **kwargs):
    """Print error messages (always shown, sent to stderr)."""
    print(*args, **kwargs, file=sys.stderr)
