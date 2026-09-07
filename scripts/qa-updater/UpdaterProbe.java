package app.vex.updaterqa;
import android.app.Instrumentation;
import android.os.Bundle;
import android.content.Context;
import java.lang.reflect.*;
import java.io.File;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class UpdaterProbe extends Instrumentation {
 public void onCreate(Bundle args){super.onCreate(args);start();}
 private void report(String s){Bundle b=new Bundle();b.putString("stream",s+"\n");sendStatus(0,b);}
 public void onStart(){
  try {
   // R10 R8 mapping: MainApplication.getReactHost -> d, ReactHost -> w, currentContext -> h.
   Context ctx=getTargetContext();ClassLoader cl=ctx.getClassLoader();
   if(ctx.getPackageManager().getPackageInfo(ctx.getPackageName(),0).versionCode!=1005660)throw new AssertionError("Probe requires exact R10 build");
   Class<?> rc=cl.loadClass("com.facebook.react.bridge.ReactApplicationContext");
   android.content.Intent launch=new android.content.Intent().setClassName(ctx.getPackageName(), "com.vexguard.app.MainActivity").addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
   startActivitySync(launch);
   Object app=ctx.getApplicationContext();Object host=app.getClass().getMethod("d").invoke(app);
   Method currentContext=cl.loadClass("com.facebook.react.w").getMethod("h");
   Object context=null;for(int i=0;i<300 && context==null;i++){context=currentContext.invoke(host);if(context==null)Thread.sleep(100);}
   if(context==null)throw new AssertionError("Real React host not ready");
   Class<?> mod=cl.loadClass("com.vexguard.app.vpn.VexVpnModule");
   Object module=null;for(int i=0;i<300 && module==null;i++){module=context.getClass().getMethod("getNativeModule",String.class).invoke(context,"VexVpn");if(module==null)Thread.sleep(100);}
   if(module==null)throw new AssertionError("Installed native module not ready");
   final Object installedModule=module;
   Method download=mod.getDeclaredMethod("downloadAndVerifyApk",String.class,String.class);download.setAccessible(true);
   String url="https://vexguard.app/downloads/qa-updater-ca94acb1d7d72ff9.apk";
   String sha="ca94acb1d7d72ff9dadd55eb24eb96272f29b88963969bfa81036cfca1f70acb";
   try { download.invoke(module,url,"0000000000000000000000000000000000000000000000000000000000000000");throw new AssertionError("bad checksum accepted"); }
   catch(InvocationTargetException e){if(!String.valueOf(e.getCause().getMessage()).contains("checksum mismatch"))throw e;report("BAD_CHECKSUM_REJECTED=PASS");}
   Object result=download.invoke(module,url,sha);
   Method getFile=result.getClass().getDeclaredMethod("b");getFile.setAccessible(true);File file=(File)getFile.invoke(result);
   report("NATIVE_DOWNLOAD_IDENTITY_CHECK=PASS bytes="+file.length());
   Class<?> promise=cl.loadClass("com.facebook.react.bridge.Promise");CountDownLatch done=new CountDownLatch(1);AtomicBoolean failed=new AtomicBoolean(false);
   Object callback=Proxy.newProxyInstance(cl,new Class[]{promise},(p,m,a)->{if(m.getName().equals("resolve")){report("INSTALL_RESULT="+String.valueOf(a[0]));done.countDown();}else if(m.getName().equals("reject")){failed.set(true);report("INSTALL_REJECTED="+String.valueOf(a[0]));done.countDown();}return null;});
   runOnMainSync(()->{try{mod.getMethod("installUpdateApk",String.class,promise).invoke(installedModule,file.getAbsolutePath(),callback);}catch(Exception e){failed.set(true);report("INSTALL_INVOKE_FAILED="+e.getClass().getSimpleName());done.countDown();}});
   if(!done.await(20,TimeUnit.SECONDS))throw new AssertionError("install timeout");
   if(failed.get())throw new AssertionError("Installer request failed");
   Bundle finish=new Bundle();finish.putString("stream","DOWNLOAD_CHECKS_PASSED_INSTALL_REQUESTED: permission grant, installer UI and post-install are separate checks\n");finish(-1,finish);
  }catch(Throwable e){Bundle b=new Bundle();b.putString("stream","PROBE_FAILED="+e.toString()+"\n");finish(0,b);}
 }
}
