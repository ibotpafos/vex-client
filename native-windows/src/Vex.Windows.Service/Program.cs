using Microsoft.Extensions.Hosting;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Service;
using Vex.Windows.Service.Ipc;
using Vex.Windows.Service.Runtime;
using Vex.Windows.Service.Security;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = WindowsServiceOptions.ServiceName;
});
builder.Services.AddSingleton(WindowsServiceOptions.Load());
builder.Services.AddSingleton<ProtectedAuthorizationStore>();
builder.Services.AddSingleton<ClientProcessAttestor>();
builder.Services.AddSingleton<ProfileSigningKeyStore>();
builder.Services.AddSingleton(provider =>
    provider.GetRequiredService<ProfileSigningKeyStore>().Load());
builder.Services.AddSingleton<IVpnTunnelRuntime, AmneziaServiceTunnelRuntime>();
builder.Services.AddSingleton<VpnServiceCommandHandler>();
builder.Services.AddSingleton<NamedPipeVpnServer>();
builder.Services.AddHostedService<VpnBackgroundService>();

await builder.Build().RunAsync();
