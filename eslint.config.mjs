import expo from "eslint-config-expo/flat.js";

export default [
  ...expo,
  {
    files: ["tests/**/*.cjs"],
    languageOptions: {
      globals: { __dirname: "readonly", __filename: "readonly" }
    }
  },
  {
    ignores: [
      ".expo/**",
      "dist/**",
      "node_modules/**",
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
