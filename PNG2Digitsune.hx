import sys.FileSystem;
import sys.io.File;
import haxe.Exception;
import haxe.io.Bytes;
import format.png.Reader as PNGReader;
import format.png.Writer as PNGWriter;
import format.png.Tools as PNGTools;
import format.png.Data as PNGData;
import cpp.UInt8;

typedef MaskData = Array<Bytes>;

class PNG2Digitsune {
	static var path:String;
	static var linearize:Bool = false;
	static var skipMouthpiece:Bool = false;
	static var omitMouthpiece:Bool = false;
	static var outPath:String;
	
	static var pngReader:PNGReader;
	static var srcData:PNGData;
	static var srcBytes:Bytes;
	
	// For 1bpp hex output
	static var assembledData:MaskData;
	// For 24bpp linear output
	static var linearizedData:Bytes;
	
	public static function main():Void {
		if (Sys.args().length == 0 || Sys.args().length > 3) {
			error("Invalid number of arguments");
		} else {
			if (Sys.args().length == 1 && StringTools.contains(Sys.args()[0], "-help")) {
				printUsage();
				Sys.exit(0);
			}
		}
		
		// Verify input file exists
		path = Sys.args()[0];
		if (!FileSystem.exists(path)) {
			error("Input file does not exist");
		}
		
		// Check extra args
		if (Sys.args().length >= 2) {
			// Specify -l without 3rd arg
			if (Sys.args().length == 2 && (Sys.args()[1] == "-l" || Sys.args()[1] == "-sl" || Sys.args()[1] == "-ls")) {
				error("Need third argument with output filename for linearization mode.");
			}
			// Look for -s
			if (Sys.args()[1] == "-s" || Sys.args()[1] == "-sl" || Sys.args()[1] == "-ls") {
				skipMouthpiece = true;
			}
			// Look for -S
			if (Sys.args()[1] == "-S") {
				omitMouthpiece = true;
			}
			// Look for -l
			if (Sys.args().length == 3) {
				if (Sys.args()[1] == "-l" || Sys.args()[1] == "-sl" || Sys.args()[1] == "-ls") {
					linearize = true;
					outPath = Sys.args()[2];
				}
			}
		}
		
		// Load image
		pngReader = new PNGReader(File.read(path));
		srcData = pngReader.read();
		
		// Verify image size
		if (skipMouthpiece || omitMouthpiece) {
			if (PNGTools.getHeader(srcData).width != 40 || PNGTools.getHeader(srcData).height != 32) {
				error("Skipping the mouthpiece requires a 40x32px image as input.");
			}
		} else {
			if (PNGTools.getHeader(srcData).width != 40 || PNGTools.getHeader(srcData).height != 40) {
				error("Converter requires a 40x40px image as input (or 40x32 with -s).");
			}
		}
		
		srcBytes = PNGTools.extract32(srcData);
		PNGTools.reverseBytes(srcBytes);
		
		if (!linearize) {
			assembledData = new MaskData();
			var tmpLine:Array<UInt8>;
			// need to do some trickery to get reversed iteration for each panel
			
			// Get mouthpiece (flipped horizontal)
			if (!skipMouthpiece && !omitMouthpiece) {
				for (y in 32...40) {
					tmpLine = new Array<UInt8>();
					for (x in 0...8) {
						tmpLine.push(getPixel(srcBytes, 23-x, y));
					}
					assembledData.push(bits2byte(tmpLine));
				}
			} else if (skipMouthpiece) {
				// If we skip the mouthpiece, just set it to blank
				for (i in 0...8) {
					assembledData.push(Bytes.alloc(1));
					assembledData[i].set(0, 0x00);
				}
			}
			// Get panel1 (flipped vertical)
			for (y in 0...32) {
				tmpLine = new Array<UInt8>();
				for (x in 0...8) {
					tmpLine.push(getPixel(srcBytes, x, 31-y));
				}
				assembledData.push(bits2byte(tmpLine));
			}
			// Get panel2 (flipped horizontal)
			for (y in 0...32) {
				tmpLine = new Array<UInt8>();
				for (x in 0...8) {
					tmpLine.push(getPixel(srcBytes, 15-x, y));
				}
				assembledData.push(bits2byte(tmpLine));
			}
			// Get panel3 (flipped vertical)
			for (y in 0...32) {
				tmpLine = new Array<UInt8>();
				for (x in 16...24) {
					tmpLine.push(getPixel(srcBytes, x, 31-y));
				}
				assembledData.push(bits2byte(tmpLine));
			}
			// Get panel4 (flipped horizontal)
			for (y in 0...32) {
				tmpLine = new Array<UInt8>();
				for (x in 0...8) {
					tmpLine.push(getPixel(srcBytes, 31-x, y));
				}
				assembledData.push(bits2byte(tmpLine));
			}
			// Get panel5 (flipped vertical)
			for (y in 0...32) {
				tmpLine = new Array<UInt8>();
				for (x in 32...40) {
					tmpLine.push(getPixel(srcBytes, x, 31-y));
				}
				assembledData.push(bits2byte(tmpLine));
			}
			
			// Everything's in place, now just output and exit
			var count:Int = 0;
			Sys.stdout().writeString("{\n");
			for (val in assembledData) {
				Sys.stdout().writeString('0x${val.toHex()}, ');
				count++;
				if (count == 16) {
					Sys.stdout().writeString('\n');
					count = 0;
				}
			}
			Sys.stdout().writeString('},\n');
			Sys.exit(0);
		} else {
			// 1344 * 3 bytes per px
			linearizedData = Bytes.alloc(4032);
			// Refers to overall position + where in the linear data to emplace (*3)
			var counter:Int = 0;
			// Determines which direction to get pixels horizontally
			var lineCounter:Int = 0;
			// Encoding the data is tricky, mostly since haxe can't do reverse iteration natively
			// This could honestly all be condensed into a single function since each panel has a similar process
			// Refer to the zigzag patterns:
			/*
			 *  +----+----+----+----+----+
			 *	|<--<|v--*|<--<|v--*|<--<|
			 *	|   |||   |   |||   |   ||
			 *	|>--^|>--v|>--^|>--v|>--^|
			 *	||   |   |||   |   |||   |
			 *	|^--<|v--<|^--<|v--<|^--<|
			 *	|   |||   |   |||   |   ||
			 *	|*--^|>-->|*--^|>-->|*--^|
			 *	+----+----+----+----+----+
			 *	          |v--*|
			 *	          ||   |
			 *	          |>-->|
			 *	          +----+
			 */
			 // Get mouthpiece
			if (!skipMouthpiece) {
				for (y in 32...40) {
					for (x in 0...8) {
						// If even, we're going backwards; otherwise forwards
						if (lineCounter % 2 == 0) {
							linearizedData.blit(counter * 3, getPixel24i(srcBytes, 23-x, y), 0, 3);
						} else {
							linearizedData.blit(counter * 3, getPixel24i(srcBytes, 16+x, y), 0, 3);
						}
						counter++;
					}
					lineCounter++;
				}
			} else {
				// If we skip the mouthpiece, just set it to blank
				linearizedData.fill(0, 64, 0);
				counter = 64;
				lineCounter = 8;
			}
			// Get panel1
			for (y in 0...32) {
				for (x in 0...8) {
					// Even? forwards; otherwise backwards
					if (lineCounter % 2 == 0) {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, x, 31-y), 0, 3);
					} else {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 7-x, 31-y), 0, 3);
					}
					counter++;
				}
				lineCounter++;
			}
			// Get panel2
			for (y in 0...32) {
				for (x in 0...8) {
					// Even? backwards; otherwise forwards
					if (lineCounter % 2 == 0) {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 15-x, y), 0, 3);
					} else {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 8+x, y), 0, 3);
					}
					counter++;
				}
				lineCounter++;
			}
			// Get panel3
			for (y in 0...32) {
				for (x in 0...8) {
					// Even? forwards; otherwise backwards
					if (lineCounter % 2 == 0) {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 16+x, 31-y), 0, 3);
					} else {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 23-x, 31-y), 0, 3);
					}
					counter++;
				}
				lineCounter++;
			}
			// Get panel4
			for (y in 0...32) {
				for (x in 0...8) {
					// Even? backwards; otherwise forwards
					if (lineCounter % 2 == 0) {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 31-x, y), 0, 3);
					} else {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 24+x, y), 0, 3);
					}
					counter++;
				}
				lineCounter++;
			}
			// Get panel5 (finally)
			for (y in 0...32) {
				for (x in 0...8) {
					// Even? forwards; otherwise backwards
					if (lineCounter % 2 == 0) {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 32+x, 31-y), 0, 3);
					} else {
						linearizedData.blit(counter * 3, getPixel24i(srcBytes, 39-x, 31-y), 0, 3);
					}
					counter++;
				}
				lineCounter++;
			}
			var outData:PNGData = PNGTools.buildRGB(1344, 1, linearizedData);
			var writer:PNGWriter = new PNGWriter(File.write(outPath));
			writer.write(outData);
		}
	}
	
	// Returns a 1 bit color.
	static function getPixel(inBytes:Bytes, x:Int, y:Int, invert:Bool = true):UInt8 {
		// Each line is 40 pixels long, so 160 bytes per line
		// ...so (x, y) is in the form (160*y)+(x*4)
		var px:Bytes = inBytes.sub((160 * y) + (x*4), 4);
		if (px.toHex() != "ff000000" && px.toHex() != "ffffffff") {
			error("Your design has invalid pixels!
The default mode expects pixels to be either 0xff000000 or 0xffffffff in ARGB color.
This only applies to pixels in the design area; NOT the corners.
If you really meant to use colors, use the -l option to get a DigitsuneViewer-compatible image.
Color at " + x + "," + y + " is 0x" + px.toHex());
		}
		// Return 1 if color is black, 0 if color is white (inverted)
		if (invert) {
			 return px.toHex() == "ff000000" ? 0x01 : 0x00;
		}
		// Return 0 if color is black, 1 if color is white
		return px.toHex() == "ff000000" ? 0x00 : 0x01;
	}
	
	// Returns a reversed 24 bit color.
	static function getPixel24i(inBytes:Bytes, x:Int, y:Int):Bytes {
		// Each line is 40 pixels long, so 160 bytes per line
		// ...so (x, y) is in the form (160*y)+(x*4)
		// We're dealing with ARGB, so move up 1 for just RGB!
		var tmp:Bytes = Bytes.alloc(3);
		tmp.blit(0, inBytes, (160 * y) + (x*4) + 3, 1);
		tmp.blit(1, inBytes, (160 * y) + (x*4) + 2, 1);
		tmp.blit(2, inBytes, (160 * y) + (x*4) + 1, 1);
		return tmp;
	}
	
	// Returns a 24 bit color.
	static function getPixel24(inBytes:Bytes, x:Int, y:Int):Bytes {
		// Each line is 40 pixels long, so 160 bytes per line
		// ...so (x, y) is in the form (160*y)+(x*4)
		// We're dealing with ARGB, so move up 1 for just RGB!
		return inBytes.sub((160 * y) + (x*4) + 1, 3);
	}
	
	// Returns a 32 bit color.
	static function getPixel32(inBytes:Bytes, x:Int, y:Int):Bytes {
		// Each line is 40 pixels long, so 160 bytes per line
		// ...so (x, y) is in the form (160*y)+(x*4)
		return inBytes.sub((160 * y) + (x*4), 4);
	}
	
	// Turns an array of 0s and 1s into a single byte
	static function bits2byte(bits:Array<UInt8>):Bytes {
		var tmp:UInt8 = 0x00;
		for (val in bits) {
			if (val != 0 && val != 1) {
				error("Error in bits->byte conversion");
			}
			tmp = tmp << 1;
			tmp = tmp | val;
		}
		var packed:Bytes = Bytes.alloc(1);
		packed.set(0, tmp);
		return packed;
	}
	
	static function printUsage() {
		Sys.stdout().writeString("PNG2Digitsune - image utility for the Digitsune mask\n");
		Sys.stdout().writeString("Usage: png2digitsune <inputFilename> [options...] [linearizedFilename]\n");
		Sys.stdout().writeString("By default, p2d will rearrange the image and output 1bpp bitmap data for use with the Arduino program.\n\n");
		Sys.stdout().writeString("-- Linearization --\n");
		Sys.stdout().writeString("Specifying -l as an option will linearize the image for use with DigitsuneViewer.\n");
		Sys.stdout().writeString("It will require an output filename after the options.\n\n");
		Sys.stdout().writeString("-- Mouthpiece skip --\n");
		Sys.stdout().writeString("Specifying -s as an option will disregard the mouthpiece. Requires a 40x32px image.\n");
		Sys.stdout().writeString("Specifying -S does the same, but will strip out the mouthpiece part entirely. Use displayPartial().\n");
		Sys.stdout().writeString("Works with both normal and linearization modes.\n\n");
		Sys.stdout().writeString("Example: png2digitsune input.png -ls linear.png\n");
	}
	
	static function error(message:String) {
		Sys.stderr().writeString(message + "\n");
		Sys.stderr().flush();
		Sys.stderr().close();
		Sys.exit(1);
	}
}
