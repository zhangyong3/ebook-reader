#!/usr/bin/env python3
"""Local-only SSE fixture. No real API credentials or external service calls."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, time, argparse

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        content=request['messages'][-1]['content']
        if self.path!='/v1/chat/completions': self.send_error(404); return
        if 'error test' in content:
            body=b'{"error":{"message":"fixture unauthorized"}}'
            self.send_response(401);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        self.send_response(200);self.send_header('Content-Type','text/event-stream; charset=utf-8');self.send_header('Cache-Control','no-cache');self.end_headers()
        chunks=['## 原句与翻译\n\n','读者在每一本书里发现一个新世界。\n\n','## 句子结构\n\n','主语 A reader，谓语 discovers，宾语 a new world。\n\n','## 语法讲解\n\n','一般现在时描述普遍规律。\n\n','## 短语与搭配\n\n','in every book：在每一本书中。\n\n','## 重点词汇\n\n','discover：发现；reader：读者。\n\n','## 举一反三\n\n','She discovers new ideas in every conversation. 她在每次交谈中发现新的想法。\n\n','## 学习提示\n\n','第三人称单数主语搭配 discovers。🌿']
        if 'cancel test' in content: chunks=chunks*20
        try:
            self.wfile.write(b': fixture heartbeat\n\n');self.wfile.flush()
            for text in chunks:
                payload=('data: '+json.dumps({'choices':[{'delta':{'content':text},'finish_reason':None}]},ensure_ascii=False)+'\n\n').encode()
                # Split an HTTP write inside a UTF-8 sequence; SSE decoding must still preserve Chinese.
                split=next((i+1 for i,b in enumerate(payload) if b>=0xE0),len(payload)//2)
                self.wfile.write(payload[:split]);self.wfile.flush();time.sleep(.015)
                self.wfile.write(payload[split:]);self.wfile.flush();time.sleep(.12)
            self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8769);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    print(f'Local SSE fixture on 127.0.0.1:{args.port}',flush=True)
    server.serve_forever()
