import re, sys, glob
from collections import defaultdict

# One script, two trees: every number in the review's metrics table comes from here, so a
# column is only ever compared with a column measured the same way.
# Counting rule: strip comments first (see review section 5) and count app + tests together.


def strip_comments(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        if src[i:i + 3] == '"""':
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append('\n' * src.count('\n', i, j)); i = j; continue
        if src[i:i + 2] == '//':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append('\n' * src.count('\n', i, j)); i = j; continue
        if src[i:i + 2] == '/*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * src.count('\n', i, j)); i = j; continue
        out.append(src[i]); i += 1
    return ''.join(out)


root = sys.argv[1].rstrip('/')
app = sorted(glob.glob(root + '/KagiPeek/**/*.swift', recursive=True))
tst = sorted(glob.glob(root + '/Tests/**/*.swift', recursive=True))
core = sorted(glob.glob(root + '/KagiPeek/Core/**/*.swift', recursive=True))
allf = app + tst


def nlines(fs):
    return sum(len(open(f).read().splitlines()) for f in fs)


def count(pat, fs=allf):
    rx = re.compile(pat)
    return sum(len(rx.findall(strip_comments(open(f).read()))) for f in fs)


def long_funcs(fs):
    out = []
    for f in fs:
        lines = strip_comments(open(f).read()).split('\n')
        start = None
        depth = 0
        for idx, l in enumerate(lines):
            if start is None and re.match(
                    r'\s*(?:@\w+\s+)*(?:public |private |fileprivate |internal |open )*'
                    r'(?:nonisolated |static |final |override |mutating |required )*func\b', l):
                start = idx; depth = 0
            if start is not None:
                depth += l.count('{') - l.count('}')
                if depth <= 0 and '{' in '\n'.join(lines[start:idx + 1]):
                    if idx - start + 1 > 80:
                        out.append((idx - start + 1, f.replace(root + '/', '')))
                    start = None
    return out


def dup_blocks(fs, N=5):
    def meaningful(b):
        ls = [l.strip() for l in b]
        return all(ls) and len(set(ls)) >= 3 and sum(1 for l in ls if len(l) >= 20) >= 2
    seen = defaultdict(set)
    for f in fs:
        ls = [l.rstrip() for l in strip_comments(open(f).read()).split('\n')]
        for i in range(len(ls) - N + 1):
            b = ls[i:i + N]
            if meaningful(b):
                seen['\n'.join(b)].add(f)
    return sum(1 for v in seen.values() if len(v) > 1)


mx = max(app, key=lambda f: len(open(f).read().splitlines()))
lf = long_funcs(allf)
print(f"root                  : {root}")
print(f"app files / lines     : {len(app)} / {nlines(app)}")
print(f"test files / lines    : {len(tst)} / {nlines(tst)}")
print(f"Core files            : {len(core)}")
print(f"functions >80 lines   : {len(lf)}  {sorted(lf, reverse=True)}")
print(f"max file              : {mx.replace(root + '/', '')} "
      f"{len(open(mx).read().splitlines())}")
print(f"Core dup >=5-line blk : {dup_blocks(core)}")
for name, pat in [("try?", r'try\?'), ("try!", r'try!'),
                  ("MainActor.assumeIsolated", r'MainActor\.assumeIsolated'),
                  ("@unchecked Sendable", r'@unchecked\s+Sendable'),
                  ("nonisolated(unsafe)", r'nonisolated\(unsafe\)'),
                  ("unsafeBitCast", r'unsafeBitCast'),
                  ("unsafeDowncast", r'unsafeDowncast'),
                  ("ObservableObject", r'ObservableObject'),
                  ("@Observable", r'@Observable\b'),
                  (".contentShape", r'\.contentShape'),
                  (".frame(width|height", r'\.frame\((?:width|height)'),
                  ("lock()", r'\.lock\(\)'), ("unlock()", r'\.unlock\(\)')]:
    print(f"{name:24s}: {count(pat)}")
