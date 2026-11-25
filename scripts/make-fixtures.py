#!/usr/bin/env python3
"""Generate original test publications and dictionaries. No third-party books or dictionary content."""
from pathlib import Path
import struct, zlib, zipfile, wave, io, math, hashlib
ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Fixtures'
FIXTURES.mkdir(exist_ok=True)
container = '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
opf = '''<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">leaf-guide-v1</dc:identifier><dc:title>页间 · 阅读器使用指南</dc:title><dc:creator>页间</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-11-24T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="three" href="three.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/><itemref idref="three"/></spine></package>'''
nav = '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">开始阅读</a></li><li><a href="two.xhtml">查词与批注</a></li><li><a href="three.xhtml">保留你的思考</a></li></ol></nav></body></html>'''
def page(title, text):
    return f'''<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN"><head><title>{title}</title></head><body><h1>{title}</h1>{text}</body></html>'''
chapters = [
    ('one.xhtml', page('开始阅读', '''<p>页间是一款在 Mac 上运行的本地电子书阅读器。这本指南也是真实的 EPUB，可以用来体验翻页、搜索、查词和批注。</p><p>一本书，一段安静的时间。你可以调整文字大小、行距和正文宽度，让阅读适合自己的节奏。</p><h2>找到舒服的排版</h2><p>点击工具栏的排版按钮，切换纸色、白昼和夜读主题。修改字号或窗口大小后，正文会重新排列，批注继续跟随文字。</p><p>按右方向键进入下一页，按左方向键返回。也可以打开左侧目录，直接前往某一章。</p>''' + ''.join(f'<p>阅读练习 {i}：慢慢读完这一段。让眼睛沿着文字移动，记下值得再次阅读的一句话。阅读位置会自动保存，关闭书籍后可以继续。</p>' for i in range(1,9)) + '<p><a href="two.xhtml">前往：查词与批注</a></p>')),
    ('two.xhtml', page('查词与批注', '''<p>双击或拖动选中文字，再点击鼠标旁工具栏的查词图标，即可查询 MDict 离线词典。先在“管理离线词典”中导入 MDX 文件，配套 MDD 文件放在相同文件夹。</p><p lang="en">A reader discovers a new world in every book. Each leaf holds a thought, and every annotation keeps a moment of understanding.</p><h2>标记一句话</h2><p>选中文字后点击高亮图标，右击已标记文字可修改颜色，以及透明色块、下划线或删除线。笔记与书籍分开保存，不会改写原始 EPUB。</p><p>黄色用于重点，绿色用于启发，粉色用于疑问。颜色只是一种选择，你也可以全部使用同一种颜色。</p><p>双击正文空白处可输入即时笔记，右击编辑框可修改字体、颜色和字号。点击书签图标留下别针，左侧书签列表可以跳回原文。</p><p>这是一条脚注示例<a epub:type="noteref" href="#note1">[1]</a>，可用于检查书内跳转和返回。</p><aside epub:type="footnote" id="note1"><p>这里是脚注内容，阅读窗口底部的返回按钮可回到跳转前的位置。</p></aside>''')),
    ('three.xhtml', page('保留你的思考', '''<p>在软件设置中配置 OpenAI 接口后，可选中语句并点击翻译图标，逐步查看语法、短语、重点词汇和例句。右侧历史可回放查词及解析，相同内容只保留最近一次。</p><p>书中留下的高亮和笔记，可以通过菜单导出为 Markdown。文件包含书名、章节、摘录和你写下的想法。</p><p>“备份全部笔记”保存 JSON 文件，恢复前请先导入对应的原版 EPUB。笔记备份不包含书籍和词库文件。</p><h2>数据保存在本机</h2><p>本应用不需要登录。书籍副本、进度和笔记保存在应用支持目录，离线词库保留在你选择的位置。</p><p>不同版本的同一本书可能有不同的排版和文字，因此会被识别为不同书籍。这样可以避免把批注放到另一个版本的错误位置。</p><p lang="en">Reading is a conversation with a book. An annotation is your reply.</p>''')),
]
def write_zip(z,name,text,compression=zipfile.ZIP_DEFLATED):
    info=zipfile.ZipInfo(name,date_time=(2026,11,24,0,0,0)); info.compress_type=compression
    z.writestr(info,text)
with zipfile.ZipFile(FIXTURES/'Guide.epub','w') as z:
    write_zip(z,'mimetype','application/epub+zip',zipfile.ZIP_STORED)
    for name,text in [('META-INF/container.xml',container),('EPUB/book.opf',opf),('EPUB/nav.xhtml',nav)]+[('EPUB/'+n,t) for n,t in chapters]:
        write_zip(z,name,text)
(ROOT/'Sources/LeafApp/Resources/Guide.epub').write_bytes((FIXTURES/'Guide.epub').read_bytes())

# Font obfuscation is not DRM: verify that the importer restores the exact font bytes.
font = bytes(range(256))*8
key = hashlib.sha1(b'leaf-guide-v1').digest()
obfuscated = bytes(byte ^ key[i % len(key)] if i < 1040 else byte for i,byte in enumerate(font))
with zipfile.ZipFile(FIXTURES/'Guide.epub') as source, zipfile.ZipFile(FIXTURES/'Obfuscated.epub','w') as target:
    for item in source.infolist(): target.writestr(item,source.read(item.filename))
    write_zip(target,'META-INF/encryption.xml','<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#"><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="EPUB/font.otf"/></CipherData></EncryptedData></encryption>')
    write_zip(target,'EPUB/font.otf',obfuscated)

def u64(n): return struct.pack('>Q',n)
def block(data,compression=2):
    if compression == 2: payload=zlib.compress(data)
    else:
        n=len(data)
        if n <= 238: payload=bytes([17+n])+data+b'\x11\0\0'
        else:
            extended=bytearray([0]); n-=18
            while n > 255: extended.append(0); n-=255
            extended.append(n); payload=bytes(extended)+data+b'\x11\0\0'
    return struct.pack('<I',compression)+struct.pack('>I',zlib.adler32(data))+payload
def mdict(path,pairs,resource=False,compression=2):
    codec='utf-16le' if resource else 'utf-8'; unit=2 if resource else 1
    header=(f'<{"Library_Data" if resource else "Dictionary"} GeneratedByEngineVersion="2.0" RequiredEngineVersion="2.0" Encrypted="0" Encoding="UTF-8" Format="Html" Title="页间示例词典" KeyCaseSensitive="No"/>\0').encode('utf-16le')
    raw=bytearray(); key=bytearray()
    for word,content in sorted(pairs):
        key+=u64(len(raw))+word.encode(codec)+b'\0'*unit
        raw+=content if resource else content.encode(codec)+b'\0'*unit
    words=[w for w,_ in sorted(pairs)]
    packed_key=block(key,compression)
    info=u64(len(pairs))
    for word in [words[0],words[-1]]:
        encoded=word.encode(codec); info+=struct.pack('>H',len(encoded)//unit)+encoded+b'\0'*unit
    info+=u64(len(packed_key))+u64(len(key)); packed_info=block(info,compression)
    key_header=b''.join(map(u64,[1,len(pairs),len(info),len(packed_info),len(packed_key)]))
    # Split inside a record to exercise the cross-block reader.
    pieces=[raw[:len(raw)//2],raw[len(raw)//2:]]; record_blocks=[block(p,compression) for p in pieces]
    record_info=b''.join(u64(len(c))+u64(len(p)) for c,p in zip(record_blocks,pieces))
    record_header=b''.join(map(u64,[len(pieces),len(pairs),len(record_info),sum(map(len,record_blocks))]))
    path.write_bytes(struct.pack('>I',len(header))+header+struct.pack('<I',zlib.adler32(header))+key_header+struct.pack('>I',zlib.adler32(key_header))+packed_info+packed_key+record_header+record_info+b''.join(record_blocks))
mdict(FIXTURES/'Leaf Demo.mdx',[
    ('annotation','<h2>annotation</h2><p>n. 批注；注释。</p><p>在阅读中保存的一条思考。</p>'),
    ('leaf','<link rel="stylesheet" href="demo.css"/><h2>leaf</h2><p>n. 叶；书页。</p><img src="images/leaf.svg"/><p><a href="sound://leaf.wav">播放示例音频</a></p>'),
    ('reader','<h2>reader</h2><p>n. 读者；阅读器。</p><p>A reader discovers a new world in every book.</p><a href="entry://annotation">查看 annotation</a>'),
    ('reading','@@@LINK=reader'),
    ('测试','<h2>测试</h2><p>这是中文词条，用于验证 UTF-8、索引和跨数据块读取。</p>')])
audio=io.BytesIO()
with wave.open(audio,'wb') as w:
    w.setparams((1,2,16000,0,'NONE','not compressed'))
    w.writeframes(b''.join(struct.pack('<h',int(3000*math.sin(2*math.pi*440*i/16000))) for i in range(4000)))
mdict(FIXTURES/'Leaf Demo.mdd',[
    ('\\demo.css',b'h2{color:#426653}'),
    ('\\images\\leaf.svg',b'<svg xmlns="http://www.w3.org/2000/svg" width="80" height="48"><rect width="80" height="48" fill="#e7efe9"/><text x="16" y="30" fill="#426653">Leaf</text></svg>'),
    ('\\leaf.wav',audio.getvalue())],resource=True)
print('Generated Guide.epub and original MDX/MDD fixtures.')

mdict(FIXTURES/'LZO Demo.mdx',[('leaf','<p>使用 LZO 压缩的词条。</p>'),('reader','<p>读者。</p>')],compression=1)
