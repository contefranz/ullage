import sys
from PIL import Image
D = '/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad/data2/pft-b2/img/native/'
pg, y, x0, x1, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
im = Image.open(D + f'nd-{pg}.png').convert('L').crop((x0, y - 6, x1, y + 32))
im = im.resize((im.width * 10, im.height * 10), Image.NEAREST)
im.save(out)
