const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const sourcePath = process.env.SIGN_IN_BOTTOM_SHEET_SOURCE
  || path.join(__dirname, '..', 'src', 'components', 'sign-in-bottom-sheet.android.tsx');
const source = fs.readFileSync(sourcePath, 'utf8');

test('Android sign-in sheet has a bounded scroll container and bottom safe-area padding', () => {
  assert.match(source, /useSafeAreaInsets/);
  assert.match(source, /verticalScroll\(\)/);
  assert.match(source, /fillMaxHeight\(\)/);
  assert.match(source, /padding\(0, 0, 0, Math\.max\(20, insets\.bottom \+ 20\)\)/);
});
