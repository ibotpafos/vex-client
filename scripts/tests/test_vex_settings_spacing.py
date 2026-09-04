from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
start=s.find('private var updateActions: some View')
assert start>=0, 'Missing separated update actions group'
group=s[start:s.index('private var helperStatusText',start)]
assert 'VStack(spacing: 10)' in group, 'Missing 10pt button gap'
assert group.count('Button {')==2, 'Both actions must share the spaced group'
assert 'updateActions\n                    .padding(.top, 8)' in s, 'Missing separation from update toggle'
print('PASS: two action buttons separated by 10pt; group inset 8pt')
