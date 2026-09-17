# PATH setup

The public command surface is the `bin` directory. It contains the `ats.cmd`
launcher and avoids placing the whole project directory on `PATH`.

From the repository root, add `bin` to the current user's PATH:

```powershell
$atsBin = (Resolve-Path .\bin).Path
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { $_ })
if ($entries.TrimEnd('\') -inotcontains $atsBin.TrimEnd('\')) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $atsBin) -join ';'), 'User')
}
```

Open a new terminal, then launch the dashboard with:

```text
ats
```

Set `ATS_ROOT` only when the runtime workspace differs from the repository
containing the launcher:

```powershell
$env:ATS_ROOT = 'D:\Personal\ATS'
```
