import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const reactIndex = readFileSync(resolve("app/static/react/index.html"), "utf8");
const scriptMatch = reactIndex.match(/src="\/static\/react\/assets\/([^"]+\.js)"/);
const styleMatch = reactIndex.match(/href="\/static\/react\/assets\/([^"]+\.css)"/);

if (!scriptMatch || !styleMatch) {
  throw new Error("Unable to find built React assets.");
}

const shell = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
    <meta name="theme-color" content="#101318" />
    <meta name="description" content="Image Gallery media dashboard for browsing, uploading, collecting, and managing media." />
    <link rel="icon" href="/Image-Gallery/favicon.ico" />
    <link rel="stylesheet" crossorigin href="/Image-Gallery/app/static/react/assets/${styleMatch[1]}" />
    <title>Image Gallery</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" crossorigin src="/Image-Gallery/app/static/react/assets/${scriptMatch[1]}"></script>
  </body>
</html>
`;

writeFileSync(resolve("index.html"), shell);
writeFileSync(resolve("404.html"), shell);
