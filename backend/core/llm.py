"""LM Studio（OpenAI 兼容接口）客户端。

注意两点：
- 本机有系统代理，访问 127.0.0.1 时必须 trust_env=False，否则请求会被代理吞掉。
- Qwen3.5 默认先思考；reasoning_effort="none" 可关闭思考。即便如此，个别情况下
  结构化输出仍会落在 reasoning_content 里，所以读取时两处都看。
"""
from __future__ import annotations

import json
from typing import Iterator

import httpx

from . import config


class LLMError(RuntimeError):
    pass


class LLM:
    def __init__(self, base_url: str = config.LLM_URL, model: str = config.LLM_MODEL, timeout: float = 300):
        self.model = model
        self.client = httpx.Client(base_url=base_url.rstrip("/"), trust_env=False, timeout=timeout)

    def _body(self, messages: list[dict], temperature: float, max_tokens: int, **extra) -> dict:
        return {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "reasoning_effort": "none",
            **extra,
        }

    def chat(self, messages: list[dict], *, temperature: float = 0.3, max_tokens: int = 1500, **extra) -> str:
        try:
            r = self.client.post("/chat/completions", json=self._body(messages, temperature, max_tokens, **extra))
        except httpx.HTTPError as e:
            raise LLMError(f"连不上本地模型服务 {self.client.base_url}：{e}") from e
        if r.status_code != 200 or not r.content:
            raise LLMError(f"本地模型返回 {r.status_code}：{r.text[:300]}")
        msg = r.json()["choices"][0]["message"]
        return (msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()

    def json(self, messages: list[dict], schema: dict, name: str = "output", *,
             temperature: float = 0.0, max_tokens: int = 2000, **extra) -> dict:
        fmt = {"type": "json_schema", "json_schema": {"name": name, "strict": True, "schema": schema}}
        text = self.chat(messages, temperature=temperature, max_tokens=max_tokens, response_format=fmt, **extra)
        try:
            return json.loads(text)
        except json.JSONDecodeError as e:
            raise LLMError(f"模型输出不是合法 JSON：{text[:300]}") from e

    def stream(self, messages: list[dict], *, temperature: float = 0.4, max_tokens: int = 1500) -> Iterator[str]:
        body = self._body(messages, temperature, max_tokens, stream=True)
        try:
            with self.client.stream("POST", "/chat/completions", json=body) as r:
                if r.status_code != 200:
                    r.read()
                    raise LLMError(f"本地模型返回 {r.status_code}：{r.text[:300]}")
                for line in r.iter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    choices = json.loads(data).get("choices") or []
                    piece = choices[0].get("delta", {}).get("content") if choices else None
                    if piece:
                        yield piece
        except httpx.HTTPError as e:
            raise LLMError(f"连不上本地模型服务 {self.client.base_url}：{e}") from e
