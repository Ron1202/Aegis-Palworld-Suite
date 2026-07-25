# Version 1.0.1 Fix

Corrected three Windows PowerShell 5.1 parser errors caused by a colon
immediately following an interpolated variable name inside a double-quoted
string. Variables are now delimited with `${...}`.

No database logic or input URLs were changed.
