"""Independent CoreSimulator movement control; never addresses physical devices."""
import pathlib
import subprocess
import sys
import time

device=sys.argv[1]
deadline=time.monotonic()+600
while time.monotonic()<deadline:
    result=subprocess.run(['xcrun','simctl','get_app_container',device,'app.waypoint.locationprobe','data'],
                          capture_output=True,text=True,timeout=10)
    if result.returncode==0:
        marker=pathlib.Path(result.stdout.strip())/'Documents/simulator-control.request'
        if marker.is_file():
            subprocess.run(['xcrun','simctl','location',device,'set','37.3369,-122.0090'],check=True,timeout=10)
            print('WAYPOINT_SIMULATOR_LIVE_CONTROL applied synthetic coordinate',flush=True)
            break
    time.sleep(0.5)
else:
    raise SystemExit('The observer did not request a simulator control within ten minutes.')
