import { mkdir, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const output = process.argv[2] ?? 'assets/map_tiles/hong_kong';
const baseUrl = process.argv[3] ?? 'http://localhost:8099/tile';
const bounds = { west: 113.8, east: 114.52, north: 22.565, south: 22.14 };
const minZoom = 10;
const maxZoom = 16;
const concurrency = 4;

function tileX(lon, zoom) {
  return Math.floor(((lon + 180) / 360) * 2 ** zoom);
}

function tileY(lat, zoom) {
  const radians = (lat * Math.PI) / 180;
  return Math.floor(
    ((1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2) *
      2 ** zoom,
  );
}

const tiles = [];
for (let z = minZoom; z <= maxZoom; z += 1) {
  const xMin = tileX(bounds.west, z);
  const xMax = tileX(bounds.east, z);
  const yMin = tileY(bounds.north, z);
  const yMax = tileY(bounds.south, z);
  for (let x = xMin; x <= xMax; x += 1) {
    for (let y = yMin; y <= yMax; y += 1) tiles.push({ z, x, y });
  }
}

let cursor = 0;
let completed = 0;
async function worker() {
  while (cursor < tiles.length) {
    const tile = tiles[cursor++];
    const directory = join(output, String(tile.z), String(tile.x));
    const destination = join(directory, `${tile.y}.png`);
    if (!existsSync(destination)) {
      const url = `${baseUrl}/${tile.z}/${tile.x}/${tile.y}.png`;
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
