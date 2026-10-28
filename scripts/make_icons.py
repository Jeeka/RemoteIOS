"""Developer-only icon generator; generated PNGs are committed, Pillow isn't needed in CI."""
from pathlib import Path
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
size = 1024
image = Image.new("RGB",(size,size))
pixels = image.load()
for y in range(size):
    for x in range(size):
        glow = max(0,1-((x-280)**2+(y-140)**2)**.5/1100)
        pixels[x,y] = (int(8+14*glow),int(15+39*glow),int(29+68*glow))
d = ImageDraw.Draw(image)
d.rounded_rectangle((164,220,860,720),radius=72,fill=(21,45,76),outline=(115,187,255),width=22)
d.line([(304,583),(304,367),(512,537),(720,367),(720,583)],fill=(233,245,255),width=47,joint="curve")
d.rounded_rectangle((466,732,558,800),radius=12,fill=(115,187,255))
d.rounded_rectangle((360,790,664,814),radius=12,fill=(115,187,255))
folder = root / "Resources"
folder.mkdir(exist_ok=True)
for name, dimension in {"Icon.png":57,"Icon@2x.png":114,"Icon-72.png":72,"Icon-72@2x.png":144,
                        "Icon60@2x.png":120,"Icon60@3x.png":180,"Icon76.png":76,"Icon76@2x.png":152,
                        "Icon83.5@2x.png":167,"MiptRDP-1024.png":1024}.items():
    image.resize((dimension,dimension),Image.Resampling.LANCZOS).save(folder/name)
