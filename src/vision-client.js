const http = require("node:http");
const https = require("node:https");

function chatCompletionsUrl(baseUrl) {
  const url = new URL(baseUrl);
  if (!/\/chat\/completions\/?$/.test(url.pathname)) {
    url.pathname = `${url.pathname.replace(/\/+$/, "")}/chat/completions`;
  }
  return url;
}

function imageUrlFromBlock(block) {
  if (!block || typeof block !== "object") return null;
  if (block.type === "image" && block.source) {
    if (block.source.type === "base64" && block.source.data) {
      return `data:${block.source.media_type || "image/jpeg"};base64,${block.source.data}`;
    }
    if (block.source.type === "url" && block.source.url) return block.source.url;
  }
  if (block.type === "image_url") {
    const value = typeof block.image_url === "object" ? block.image_url?.url : block.image_url;
    if (typeof value === "string" && value) return value;
  }
  return null;
}

function messageText(message) {
  if (typeof message?.content === "string") return message.content.trim();
  if (!Array.isArray(message?.content)) return "";
  return message.content
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text.trim())
    .filter(Boolean)
    .join("\n");
}

function describeImage(imageUrl, options = {}) {
  const baseUrl = options.baseUrl || process.env.VISION_BASE_URL || "https://api.stepfun.com/v1";
  const apiKey = options.apiKey || process.env.VISION_API_KEY || "";
  const model = options.model || process.env.VISION_MODEL || "step-3.7-flash";
  const prompt = options.prompt || "请详细描述这张图片的内容。";
  const timeoutMs = Number(options.timeoutMs || process.env.VISION_TIMEOUT_MS || 120000);
  if (!apiKey) return Promise.reject(new Error("VISION_API_KEY is not configured"));

  const url = chatCompletionsUrl(baseUrl);
  const transport = url.protocol === "https:" ? https : http;
  const body = JSON.stringify({
    model,
    messages: [{ role: "user", content: [
      { type: "image_url", image_url: { url: imageUrl } },
      { type: "text", text: prompt },
    ] }],
    stream: false,
    max_tokens: 1024,
  });

  return new Promise((resolve, reject) => {
    const req = transport.request(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    }, (res) => {
      let data = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        if ((res.statusCode || 500) >= 400) {
          reject(new Error(`Vision API ${res.statusCode}: ${data.slice(0, 300)}`));
          return;
        }
        try {
          const message = JSON.parse(data)?.choices?.[0]?.message;
          const text = messageText(message) || message?.reasoning_content?.trim();
          resolve(text || "[图片识别失败：视觉服务未返回描述]");
        } catch (error) {
          reject(new Error(`Vision API response is invalid: ${error.message}`));
        }
      });
    });
    req.on("error", reject);
    req.setTimeout(timeoutMs, () => req.destroy(new Error(`Vision API timed out after ${timeoutMs} ms`)));
    req.end(body);
  });
}

module.exports = { describeImage, imageUrlFromBlock };
