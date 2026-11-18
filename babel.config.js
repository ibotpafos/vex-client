module.exports = function (api) {
  api.cache(true);

  const presets = ['babel-preset-expo'];

  const plugins = [
    // React Compiler — автоматическая мемоизация useMemo/useCallback/useEffect
    // для всех компонентов. Убирает ручной шум, снижает ре-рендеры.
    ['babel-plugin-react-compiler', { target: '19' }],
  ];

  return {
    presets,
    plugins,
  };
};
