"""Read exact-black coverage of source emission PNGs; does not modify images."""

import sys

from PIL import Image

for filename in sys.argv[1:]:
    with Image.open(filename) as source:
        image = source.convert("RGB")
        histogram = image.getcolors(image.width * image.height)
        black = sum(count for count, color in histogram if color == (0, 0, 0))
        print(filename, image.size, "exact_black_percent", 100 * black / (image.width * image.height))
