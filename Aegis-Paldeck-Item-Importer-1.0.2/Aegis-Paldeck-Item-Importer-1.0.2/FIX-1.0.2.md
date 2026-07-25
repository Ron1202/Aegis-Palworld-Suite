# Version 1.0.2 Fix

Corrected Windows PowerShell 5.1 startup failure:

```text
Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
```

The script no longer uses `$PSScriptRoot` inside parameter default expressions.
It now resolves the script directory immediately after parameter binding using:

1. `$PSScriptRoot`
2. `$MyInvocation.MyCommand.Path`
3. the current working directory as a final fallback

No item URLs or extraction logic were changed.
