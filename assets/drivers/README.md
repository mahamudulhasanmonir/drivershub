# Driver Payloads

Place the silent-installable driver package contents here.

Expected layout:

- `adb/`
- `fastboot/`
- `qualcomm/`

Each folder should contain:

- `driver-package.json`
- the driver INF files
- supporting CAT/SYS files needed for installation

The package descriptor tells the installer which files should be present and which install mode to use.
