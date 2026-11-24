#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#define T(...) do{ printf(__VA_ARGS__); fflush(stdout); }while(0)
int main(void){
  setvbuf(stdout,NULL,_IONBF,0);
  const char *lib = getenv("PANVK") ? getenv("PANVK") : "/opt/panvk/libvulkan_panfrost_g.so";
  void *H = dlopen(lib, RTLD_NOW|RTLD_GLOBAL);
  T("dlopen %s -> %p err=%s\n", lib, H, H?"-":dlerror());
  if(!H) return 1;
  VkResult (*neg)(uint32_t*) = dlsym(H,"vk_icdNegotiateLoaderICDInterfaceVersion");
  PFN_vkVoidFunction (*g)(VkInstance,const char*) = dlsym(H,"vk_icdGetInstanceProcAddr");
  uint32_t v=5; VkResult rc=neg(&v); T("neg rc=%d iface=%u\n",rc,v);
  PFN_vkEnumerateInstanceLayerProperties EL=(PFN_vkEnumerateInstanceLayerProperties)g(NULL,"vkEnumerateInstanceLayerProperties");
  PFN_vkEnumerateInstanceExtensionProperties EE=(PFN_vkEnumerateInstanceExtensionProperties)g(NULL,"vkEnumerateInstanceExtensionProperties");
  PFN_vkCreateInstance CI=(PFN_vkCreateInstance)g(NULL,"vkCreateInstance");
  PFN_vkEnumeratePhysicalDevices EPD=NULL;
  PFN_vkGetPhysicalDeviceProperties GPP=NULL;
  PFN_vkGetPhysicalDeviceQueueFamilyProperties GQF=NULL;
  PFN_vkCreateDevice CD=NULL;
  T("syms EL=%p EE=%p CI=%p\n",(void*)EL,(void*)EE,(void*)CI);
  if(!CI){T("STUCK\n");return 1;}
  VkResult r; uint32_t n=0;
  r=EL(&n,NULL); T("P1 rc=%d layers=%u\n",r,n);
  n=0; r=EE(NULL,&n,NULL); T("P2 rc=%d ext=%u\n",r,n);
  VkApplicationInfo app; memset(&app,0,sizeof app); app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO; app.apiVersion=VK_API_VERSION_1_1;
  VkInstanceCreateInfo ci; memset(&ci,0,sizeof ci); ci.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; ci.pApplicationInfo=&app;
  VkInstance inst=NULL;
  r=CI(&ci,NULL,&inst); T("P3 rc=%d inst=%p\n",r,(void*)inst); if(r)return 1;
  EPD=(PFN_vkEnumeratePhysicalDevices)g(inst,"vkEnumeratePhysicalDevices");
  GPP=(PFN_vkGetPhysicalDeviceProperties)g(inst,"vkGetPhysicalDeviceProperties");
  GQF=(PFN_vkGetPhysicalDeviceQueueFamilyProperties)g(inst,"vkGetPhysicalDeviceQueueFamilyProperties");
  CD=(PFN_vkCreateDevice)g(inst,"vkCreateDevice");
  n=0; r=EPD(inst,&n,NULL); T("P4 rc=%d devices=%u\n",r,n); if(r||!n)return 1;
  VkPhysicalDevice pd; n=1; EPD(inst,&n,&pd);
  VkPhysicalDeviceProperties props; GPP(pd,&props);
  T("P5 name=%s type=%d api=%u.%u\n",props.deviceName,props.deviceType,VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion));
  n=0; GQF(pd,&n,NULL); VkQueueFamilyProperties fams[8]; if(n>8)n=8; GQF(pd,&n,fams);
  T("P6 fams=%u flags0=0x%x\n",n,fams[0].queueFlags);
  float pr=1.0f;
  VkDeviceQueueCreateInfo q; memset(&q,0,sizeof q); q.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO; q.queueFamilyIndex=0; q.queueCount=1; q.pQueuePriorities=&pr;
  VkDeviceCreateInfo d; memset(&d,0,sizeof d); d.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO; d.queueCreateInfoCount=1; d.pQueueCreateInfos=&q;
  VkDevice dev=NULL; r=CD(pd,&d,NULL,&dev); T("P6b rc=%d dev=%p\n",r,(void*)dev); if(r)return 1;
  PFN_vkGetDeviceProcAddr GD=(PFN_vkGetDeviceProcAddr)g(inst,"vkGetDeviceProcAddr");
#define D(name) PFN_vk##name name=(PFN_vk##name)GD(dev,#name)
  D(GetDeviceQueue); D(CreateCommandPool); D(AllocateCommandBuffers); D(BeginCommandBuffer); D(EndCommandBuffer); D(QueueSubmit); D(CreateFence); D(WaitForFences); D(DeviceWaitIdle);
  VkQueue queue=NULL; GetDeviceQueue(dev,0,0,&queue);
  VkCommandPoolCreateInfo pc2; memset(&pc2,0,sizeof pc2); pc2.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO; pc2.queueFamilyIndex=0;
  VkCommandPool pool; r=CreateCommandPool(dev,&pc2,NULL,&pool); T("P7 pool rc=%d\n",r); if(r)return 1;
  VkCommandBufferAllocateInfo ba; memset(&ba,0,sizeof ba); ba.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO; ba.commandPool=pool; ba.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ba.commandBufferCount=1;
  VkCommandBuffer cb; r=AllocateCommandBuffers(dev,&ba,&cb); T("P7 alloc rc=%d\n",r); if(r)return 1;
  VkCommandBufferBeginInfo bb; memset(&bb,0,sizeof bb); bb.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  r=BeginCommandBuffer(cb,&bb); if(!r)EndCommandBuffer(cb); T("P7 be rc=%d\n",r); if(r)return 1;
  VkFenceCreateInfo fc; memset(&fc,0,sizeof fc); fc.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  VkFence fence; r=CreateFence(dev,&fc,NULL,&fence); if(r)return 1;
  VkSubmitInfo s; memset(&s,0,sizeof s); s.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO; s.commandBufferCount=1; s.pCommandBuffers=&cb;
  r=QueueSubmit(queue,1,&s,fence); T("P7 submit rc=%d\n",r); if(r)return 1;
  r=WaitForFences(dev,1,&fence,1,3000000000ull); T("P7 fence rc=%d\n",r);
  DeviceWaitIdle(dev);
  T("GLIBC-PANVK-CHAIN-OK\n");
  return 0;
}
