import sys
from PIL import Image
# usage: cells.py out.png scale page:time[,time...] col[,col...]
D = '/tmp/claude-0/-home-user-ullage/1c835ba6-4d0a-5d42-96bb-a9ff7c081ab9/scratchpad/data2/pft-b2/img/native/'
first = {104: None, 105: (15, 559), 106: None, 107: (94, 560), 108: (136, 511)}
y104 = {-16 + k: v for k, v in enumerate([671,708,744,781,817,853,890,926,963,999,1035,1071,1107,1143,1179,1213,1252])}
y104.update({0.3: 1361, 0.6: 1506})
y104.update({float(1 + k): v for k, v in enumerate([1578,1614,1650,1686,1722,1758,1794,1830,1866,1902,1938,1974,2010,2047])})
y105 = {float(15 + k): v for k, v in enumerate([559,595,631,667,704,740,776,813,849,885,922,958,994,1030,1066,1102,1138,1174,1211,1247,1283,1319,1356,1392,1428,1465,1501,1537,1574,1609,1645,1682,1718,1754,1790,1827,1863,1899,1935,1971,2008,2043,2079])}
y106 = {58.:529,59.:566,60.:602,61.:639,62.:675,63.:712,64.:749,65.:785,66.:820,66.3:929,67.:1002,68.:1038,69.:1074,70.:1111,71.:1147,72.:1184,73.:1220,74.:1256,75.:1292,76.:1329,77.:1364,78.:1398,79.:1437,80.:1473,81.:1509,82.:1546,83.:1654,84.:1726,85.:1762,86.:1797,87.:1834,88.:1870,89.:1906,90.:1942,91.:1978,92.:2014,93.:2051}
y107 = {float(94 + k): v for k, v in enumerate([560,597,632,669,706,742,779,815,850,887,923,959,996,1032,1068,1105,1140,1177,1213,1249,1285,1321,1357,1394,1430,1466,1503,1538,1575,1611,1648,1684,1720,1756,1792,1828,1864,1901,1937,1972,2009,2044])}
y107[135.2] = 2153
y108 = {float(136 + k): v for k, v in enumerate([511,548,583,620,656,692,728,765,801,838,874,910,947,983,1019,1055,1093,1128,1165,1201,1237,1274,1310,1345,1381,1418])}
y108.update({161.63: 1526, 162.0: 1599})
Y = {104: y104, 105: y105, 106: y106, 107: y107, 108: y108}
COL = {'t': (320, 500), 'xs': (615, 920), 'ys': (965, 1170), 'zs': (1240, 1450), 'dxs': (1520, 1745),
       'dys': (1790, 1960), 'dzs': (2070, 2220), 'ddxs': (2290, 2490), 'ddys': (2580, 2745), 'ddzs': (2850, 3005)}
out, scale = sys.argv[1], int(sys.argv[2])
specs = sys.argv[3].split(';')
cols = ['t'] + sys.argv[4].split(',')
pieces = []
for spec in specs:
    pg, ts = spec.split(':')
    pg = int(pg)
    im = Image.open(D + f'nd-{pg}.png').convert('L')
    for t in ts.split(','):
        y = Y[pg][float(t)]
        row = [im.crop((COL[c][0], y - 8, COL[c][1], y + 34)) for c in cols]
        w = sum(p.width for p in row) + 20 * (len(row) - 1)
        canvas = Image.new('L', (w, 42), 255)
        x = 0
        for p in row:
            canvas.paste(p, (x, 0)); x += p.width + 20
        pieces.append(canvas)
W_ = max(p.width for p in pieces)
H = sum(p.height + 6 for p in pieces)
c = Image.new('L', (W_, H), 255)
y = 0
for p in pieces:
    c.paste(p, (0, y)); y += p.height + 6
c = c.resize((c.width * scale, c.height * scale), Image.NEAREST)
c.save(out)
print(c.size)
