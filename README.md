# DBADMIN-CODEX

This repository provides a Bash script (`dbdeenkus.sh`) for diagnosing and recovering Fly.io PostgreSQL clusters. A simple Textual front‑end (`frontend.py`) is also included to make common tasks accessible from a menu driven interface.

## Requirements

- Bash
- Python 3.10+
- [Textual](https://github.com/Textualize/textual) (`pip install textual`)

## Usage

Run the Textual front end:

```bash
python frontend.py
```

Select an action from the menu to run the corresponding option from `dbdeenkus.sh`.

The original Bash script can still be executed directly if preferred:

```bash
bash dbdeenkus.sh
```
