/* Additive JNI bridge; upstream legacy entrypoints stay unchanged. */
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

struct go_string { const char *str; long n; };
extern int32_t awgTurnOnRouted(struct go_string, int32_t, struct go_string, struct go_string, uint64_t, int64_t, int32_t);
extern void awgRouterSetUnderlying(int32_t, int64_t);
extern int32_t awgRouterUpdatePolicy(int32_t, struct go_string);
extern int32_t awgRouterCaptureActive(int32_t);
extern int32_t awgRouterPolicyActive(int32_t);
extern void awgRouterRelease(int32_t);

struct protector {
  uint64_t id;
  JavaVM *vm;
  jobject callback;
  jmethodID method;
  unsigned active;
};
static struct protector protectors[64];
static uint64_t next_id = 1;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t drained = PTHREAD_COND_INITIALIZER;

static uint64_t register_protector(JNIEnv *env, jobject callback) {
  if (!callback) return 0;
  pthread_mutex_lock(&gate);
  struct protector *p = NULL;
  for (unsigned i=0;i<64;i++) if (!protectors[i].id && !protectors[i].callback) { p=&protectors[i]; break; }
  if (!p) { pthread_mutex_unlock(&gate); return 0; }
  jclass clazz = (*env)->GetObjectClass(env,callback);
  p->method = (*env)->GetMethodID(env,clazz,"prepare","(IJI)Z");
  (*env)->DeleteLocalRef(env,clazz);
  if (!p->method || (*env)->GetJavaVM(env,&p->vm)!=JNI_OK) { pthread_mutex_unlock(&gate); return 0; }
  p->callback = (*env)->NewGlobalRef(env,callback);
  if (!p->callback) { pthread_mutex_unlock(&gate); return 0; }
  p->id = next_id++;
  uint64_t id=p->id;
  pthread_mutex_unlock(&gate);
  return id;
}

int vex_prepare_socket(uint64_t context, int fd, int64_t generation, int purpose) {
  pthread_mutex_lock(&gate);
  struct protector *p=NULL;
  for (unsigned i=0;i<64;i++) if (protectors[i].id==context) { p=&protectors[i]; break; }
  if (!p || purpose<0 || purpose>2) { pthread_mutex_unlock(&gate); return 0; }
  p->active++;
  pthread_mutex_unlock(&gate);
  JNIEnv *env=NULL;
  int attached=0, result=0;
  jint status=(*p->vm)->GetEnv(p->vm,(void**)&env,JNI_VERSION_1_6);
  if (status==JNI_EDETACHED) {
    if ((*p->vm)->AttachCurrentThread(p->vm,&env,NULL)==JNI_OK) attached=1;
    else env=NULL;
  }
  if (env) {
    result=(*env)->CallBooleanMethod(env,p->callback,p->method,(jint)fd,(jlong)generation,(jint)purpose)==JNI_TRUE;
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); result=0; }
  }
  if (attached) (*p->vm)->DetachCurrentThread(p->vm);
  pthread_mutex_lock(&gate);
  p->active--;
  pthread_cond_broadcast(&drained);
  pthread_mutex_unlock(&gate);
  return result;
}

void vex_release_protector(uint64_t context) {
  pthread_mutex_lock(&gate);
  struct protector *p=NULL;
  for(unsigned i=0;i<64;i++) if(protectors[i].id==context){p=&protectors[i];break;}
  if(!p){pthread_mutex_unlock(&gate);return;}
  p->id=0; // New calls fail before the reference is deleted.
  while(p->active) pthread_cond_wait(&drained,&gate);
  JNIEnv *env=NULL;int attached=0;
  if((*p->vm)->GetEnv(p->vm,(void**)&env,JNI_VERSION_1_6)==JNI_EDETACHED)
    if((*p->vm)->AttachCurrentThread(p->vm,&env,NULL)==JNI_OK)attached=1;
  if(env)(*env)->DeleteGlobalRef(env,p->callback);
  if(attached)(*p->vm)->DetachCurrentThread(p->vm);
  p->callback=NULL;p->method=NULL;p->vm=NULL;
  pthread_mutex_unlock(&gate);
}

JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgTurnOnRouted(JNIEnv *env,jclass cls,jstring name,jint fd,jstring settings,jstring params,jobject callback,jlong generation,jboolean retain) {
  uint64_t protector=register_protector(env,callback);
  if(!protector)return -1;
  const char *n=(*env)->GetStringUTFChars(env,name,0),*s=(*env)->GetStringUTFChars(env,settings,0),*p=(*env)->GetStringUTFChars(env,params,0);
  int ret=-1;
  if(n&&s&&p)ret=awgTurnOnRouted((struct go_string){n,(*env)->GetStringUTFLength(env,name)},fd,
    (struct go_string){s,(*env)->GetStringUTFLength(env,settings)},(struct go_string){p,(*env)->GetStringUTFLength(env,params)},protector,generation,retain);
  if(n)(*env)->ReleaseStringUTFChars(env,name,n);
  if(s)(*env)->ReleaseStringUTFChars(env,settings,s);
  if(p)(*env)->ReleaseStringUTFChars(env,params,p);
  if(ret==-1)vex_release_protector(protector);
  return ret;
}
JNIEXPORT void JNICALL Java_org_amnezia_awg_GoBackend_awgRouterSetUnderlying(JNIEnv *env,jclass cls,jint id,jlong generation){awgRouterSetUnderlying(id,generation);}
JNIEXPORT jint JNICALL Java_org_amnezia_awg_GoBackend_awgRouterUpdatePolicy(JNIEnv *env,jclass cls,jint id,jstring params){
  const char *p=(*env)->GetStringUTFChars(env,params,0);if(!p)return -1;
  int ret=awgRouterUpdatePolicy(id,(struct go_string){p,(*env)->GetStringUTFLength(env,params)});
  (*env)->ReleaseStringUTFChars(env,params,p);return ret;
}
JNIEXPORT jboolean JNICALL Java_org_amnezia_awg_GoBackend_awgRouterCaptureActive(JNIEnv *env,jclass cls,jint id){return awgRouterCaptureActive(id)!=0;}
JNIEXPORT jboolean JNICALL Java_org_amnezia_awg_GoBackend_awgRouterPolicyActive(JNIEnv *env,jclass cls,jint id){return awgRouterPolicyActive(id)!=0;}
JNIEXPORT void JNICALL Java_org_amnezia_awg_GoBackend_awgRouterRelease(JNIEnv *env,jclass cls,jint id){awgRouterRelease(id);}

extern char *awgRouterAuthorization(int32_t);
JNIEXPORT jstring JNICALL Java_org_amnezia_awg_GoBackend_awgRouterAuthorization(JNIEnv *env,jclass cls,jint id){
  char *authorization=awgRouterAuthorization(id);if(!authorization)return NULL;
  jstring result=(*env)->NewStringUTF(env,authorization);free(authorization);return result;
}
