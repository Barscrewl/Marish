# Headless Marish test

`marish_watch.lua` is a LuaUI widget for an isolated test game. It:

- runs the game at up to 20x (`SPEED`) from frame 1 and quits at minute 16 (`END_MIN`)
- logs every team's metal/energy income and its factories and combat units once a game minute
  (`[Marish] min N team T m=.. e=.. | unit=count ...`)
- logs the first time each team finishes each factory or combat unit, with game time and income
  (`[Marish] first T2lab armalab team 5 at 13:27 (metal income 35)`); factory kinds
  `T1lab`, `T2lab`, `gantry`, `VEHPLANT`, `HOVER`, `AIRPLANT`

The engine's Lua is 5.1: no `//` integer division (use `math.floor`). A widget that
fails to parse only shows up as `Failed to load: marish_watch.lua` in the infolog.

`headless_script.txt` is the start script it was used with: 3v3, all Marish, Armada,
Cortex and Legion on each side, on Starwatcher 1.0, spectator on its own ally team,
`allowuserwidgets=1`. Its AI is `MarishTest`/`test` so the test copy never clashes with
the installed `Marish`/`stable`. Update `GameType` from `data\_script.txt` when BAR updates.

## Staging (PowerShell)

```powershell
$data = "$env:LOCALAPPDATA\Programs\Beyond-All-Reason\data"
$eng  = "$data\engine\recoil_2026.07.04"
$repo = "C:\Users\artib\BAR\Marish"
$d    = "C:\bar-games\marish-test"     # any empty folder; one per running copy

$ai = "$d\AI\Skirmish\MarishTest\test"
New-Item -ItemType Directory -Force $ai, "$d\LuaUI\Widgets" | Out-Null
Copy-Item "$repo\stable\SkirmishAI.dll", "$repo\stable\AIOptions.lua" $ai
Copy-Item -Recurse -Force "$repo\stable\config", "$repo\stable\script" $ai
(Get-Content "$repo\stable\AIInfo.lua") -replace "'Marish', -- AI name", "'MarishTest', -- AI name" `
  -replace "'stable', -- AI version", "'test', -- AI version" | Set-Content "$ai\AIInfo.lua" -Encoding ascii
Copy-Item "$repo\tools\playtest\marish_watch.lua" "$d\LuaUI\Widgets\"
Copy-Item "$repo\tools\playtest\headless_script.txt" "$d\script.txt"
"SpringData = $data`r`nLogFlush = 1" | Set-Content "$d\springsettings.cfg" -Encoding ascii

Start-Process "$eng\spring-headless.exe" -WorkingDirectory $eng -WindowStyle Hidden `
  -ArgumentList '--write-dir', "`"$d`"", "`"$d\script.txt`""
```

Then read `$d\infolog.txt`: `Select-String '\[Marish\]|\[LandArmy\]' $d\infolog.txt`.
A 16-minute game takes about 4 minutes with six AIs.
