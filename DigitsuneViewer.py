import board
import neopixel
import png

disp = neopixel.NeoPixel(board.D18, 1344, brightness = 0.08, auto_write = False)
pngReader = png.Reader(filename="linTest.png")
pngData = list(list(pngReader.read()[2])[0])
disp.fill((0, 0, 0))

for pix in range(1344):
	disp[pix] = (pngData[pix * 3], pngData[(pix * 3) + 1], pngData[(pix * 3) + 2])

disp.show()