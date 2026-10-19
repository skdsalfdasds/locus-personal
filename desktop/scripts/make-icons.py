from pathlib import Path
from PIL import Image, ImageDraw

root=Path(__file__).resolve().parent.parent
directory=root/'assets/icons';directory.mkdir(parents=True,exist_ok=True)
image=Image.new('RGBA',(1024,1024),(0,0,0,0))
draw=ImageDraw.Draw(image)
draw.rounded_rectangle((6,6,1018,1018),radius=225,fill='#292f25')
draw.polygon([(271,466),(765,259),(551,769),(478,545)],fill='#cfeaa9')
draw.polygon([(347,464),(696,319),(535,681),(520,506)],fill='#292f25')
image.save(directory/'waypoint.png')
image.save(directory/'waypoint.ico',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
image.save(directory/'waypoint.icns')
