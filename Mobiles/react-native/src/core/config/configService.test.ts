describe('local telemetry config on both platforms', () => {
  function load(platform: string, config: Record<string, string>) {
    jest.resetModules();
    jest.doMock('react-native', () => ({ Platform: { OS: platform } }));
    jest.doMock('../../../config.json', () => config);
    jest.doMock('../../features/debug/domain/debugSettingsStore', () => ({
      loadSavedDebugSettings: jest.fn().mockResolvedValue({}),
    }));
    return require('./configService');
  }

  it.each(['ios', 'android'])(
    'selects the %s host from one shared config',
    async platform => {
      const service = load(platform, {
        BASE_URL: '',
        PORT: '29333',
        FARO_COLLECTOR_URL: 'https://legacy.test/collect',
        FARO_COLLECTOR_URL_IOS: 'http://127.0.0.1:17134/collect/react-native',
        FARO_COLLECTOR_URL_ANDROID:
          'http://10.0.2.2:17134/collect/react-native',
      });
      const config = await service.initializeRuntimeConfig();
      expect(config.baseUrl).toBe(
        `http://${platform === 'android' ? '10.0.2.2' : 'localhost'}:29333`,
      );
      expect(config.faroCollectorUrl).toBe(
        `http://${
          platform === 'android' ? '10.0.2.2' : '127.0.0.1'
        }:17134/collect/react-native`,
      );
    },
  );

  it('keeps ordinary single-endpoint configs working', () => {
    const service = load('android', {
      FARO_COLLECTOR_URL: 'https://original.test/collect',
    });
    expect(service.getFaroCollectorUrl()).toBe('https://original.test/collect');
  });
});
