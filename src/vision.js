#!/usr/bin/env node
/** Independent image-to-text CLI inspired by the asuojun/claude-vision-skill workflow. */
const fs = require("node:fs");
const path = require("node:path");
const { describeImage } = require("./vision-client");

function parseArgs() {
  const argv = process.argv.slice(2);
  let imageSource = "";
  let prompt = "";
  let isUrl = false;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--url" && argv[i + 1]) {
      isUrl = true;
      imageSource = argv[++i];
    } else if (!imageSource && !argv[i].startsWith("--")) {
      imageSource = argv[i];
    } else if (imageSource && !argv[i].startsWith("--")) {
      prompt = prompt ? `${prompt} ${argv[i]}` : argv[i];
    }
  }
  return { imageSource, isUrl, prompt: prompt || "请详细描述这张图片的内容。" };
}

function imageUrl(source, isUrl) {
  if (isUrl) return source;
  const resolved = path.resolve(source);
  if (!fs.existsSync(resolved)) throw new Error(`文件不存在: ${resolved}`);
  const ext = path.extname(resolved).toLowerCase().slice(1);
  const mime = { jpg: "jpeg", jpeg: "jpeg", png: "png", gif: "gif", webp: "webp", bmp: "bmp" };
  return `data:image/${mime[ext] || "jpeg"};base64,${fs.readFileSync(resolved).toString("base64")}`;
}

async function main() {
  const args = parseArgs();
  if (!args.imageSource) {
    throw new Error("用法: node vision.js <图片路径> [问题]\n      node vision.js --url <图片链接> [问题]");
  }
  console.log(await describeImage(imageUrl(args.imageSource, args.isUrl), { prompt: args.prompt }));
}

main().catch((error) => {
  console.error(`识图失败: ${error.message}`);
  process.exitCode = 1;
});
