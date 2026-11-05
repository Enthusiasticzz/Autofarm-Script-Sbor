# Working body contour backup

`Esp-body-contour.lua` is an untouched snapshot of `script/Features/Esp.lua`
from commit `35d0d7b`, before the optional Smooth renderer was added.
It includes the working body-only contour, boxes, menu clipping and caches.

The active script still offers this renderer as **Body contour** (the default).
To restore the complete snapshot, copy it over `script/Features/Esp.lua` and run
`powershell -ExecutionPolicy Bypass -File tools/build-bundle.ps1`.

Files under References are excluded from the runtime bundle.
