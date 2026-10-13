using Microsoft.Extensions.Hosting;
using Vex.Windows.Core.Vpn;
using Vex.Windows.Service;
using Vex.Windows.Service.Ipc;
using Vex.Windows.Service.Runtime;
using Vex.Windows.Service.Security;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.Configure<HostOptions>(options =>
{
    options.ShutdownTimeout = VpnRuntimeLifetimePolicy.HostShutdownTimeout;
});
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
builder.Services.AddSingleton<IVpnTunnelRuntime>(provider => {
    var options = provider.GetRequiredService<WindowsServiceOptions>();
    // Old protected installations have no routed capability and retain their
    // original runtime. A provisioned router must pass its sealed trust gate.
    if (File.Exists(Path.Combine(options.DataDirectory, "router-sha256"))) { return new RoutedAwgTunnelRuntime(options); }
    if (File.Exists(Path.Combine(options.DataDirectory, "Private", "routed-lease.json"))) { throw new VpnTunnelException("routing_reinstall_required"); }
    return new AmneziaServiceTunnelRuntime(options);
});
builder.Services.AddSingleton<VpnServiceCommandHandler>();
builder.Services.AddSingleton<NamedPipeVpnServer>();
builder.Services.AddHostedService<VpnBackgroundService>();

await builder.Build().RunAsync();
