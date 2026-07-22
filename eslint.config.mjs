import expo from "eslint-config-expo/flat.js";

export default [
  ...expo,
  {
    ignores: [
      ".expo/**",
      "dist/**",
      "node_modules/**",
      "src-tauri/**",
      "android/**",
      "ios/**",
      "external/**",
      "certs/**",
      "scripts/**",
      "artifacts/**",
      ".worktrees/**"
    ]
  },
  {
    rules: {
      "react-hooks/set-state-in-effect": "off",
      "react-hooks/refs": "off",
      "react-hooks/preserve-manual-memoization": "off",
      "react-hooks/immutability": "off"
    }
  }
];
