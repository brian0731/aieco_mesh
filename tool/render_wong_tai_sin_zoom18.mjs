import { mkdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const output = process.argv[2] ?? 'assets/map_tiles/hong_kong';
const baseUrl = process.argv[3] ?? 'http://localhost:8099/tile';
const bounds = { west: 114.18, east: 114.24, north: 22.36, south: 22.32 };
const zoom = 18;
const concurrency = 4;

const tileX = (lon) => Math.floor(((lon + 180) / 360) * 2 ** zoom);
const tileY = (lat) => {
  const radians = (lat * Math.PI) / 180;
  return Math.floor(
    ((1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2) *
      2 ** zoom,
  );
};

const tiles = [];
for (let x = tileX(bounds.west); x <= tileX(bounds.east); x += 1) {
  for (let y = tileY(bounds.north); y <= tileY(bounds.south); y += 1) {
    tiles.push({ x, y });
  }
}

let cursor = 0;
let completed = 0;
async function worker() {
  while (cursor < tiles.length) {
    const tile = tiles[cursor++];
    const directory = join(output, String(zoom), String(tile.x));
    const destination = join(directory, `${tile.y}.png`);
    if (!existsSync(destination)) {
      const url = `${baseUrl}/${zoom}/${tile.x}/${tile.y}.png`;
      let response;
      for (let attempt = 1; attempt <= 8; attempt += 1) {
        response = await fetch(url);
        if (response.ok) break;
        await new Promise((resolve) => setTimeout(resolve, attempt * 750));
      }
      if (!response?.ok) throw new Error(`Tile failed: ${url} (${response?.status})`);
      await mkdir(directory, { recursive: true });
      await writeFile(destination, Buffer.from(await response.arrayBuffer()));
    }
    completed += 1;
    if (completed % 250 === 0 || completed === tiles.length) {
      process.stdout.write(`Rendered ${completed}/${tiles.length}\n`);
    }
  }
}

await Promise.all(Array.from({ length: concurrency }, () => worker()));
