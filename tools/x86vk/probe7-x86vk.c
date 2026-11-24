#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>
#define T(...) do{ printf(__VA_ARGS__); fflush(stdout); }while(0)
int main(void){
  setvbuf(stdout,NULL,_IONBF,0);
  uint32_t n=0; VkResult r;
  r=vkEnumerateInstanceLayerProperties(&n,NULL); T("P1 rc=%d layers=%u\n",r,n);
  n=0; r=vkEnumerateInstanceExtensionProperties(NULL,&n,NULL); T("P2 rc=%d ext=%u\n",r,n);
  VkApplicationInfo app; memset(&app,0,sizeof app); app.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO; app.apiVersion=VK_API_VERSION_1_1;
  VkInstanceCreateInfo ci; memset(&ci,0,sizeof ci); ci.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; ci.pApplicationInfo=&app;
  VkInstance inst=NULL;
  r=vkCreateInstance(&ci,NULL,&inst); T("P3 rc=%d inst=%p\n",r,(void*)inst); if(r)return 1;
  n=0; r=vkEnumeratePhysicalDevices(inst,&n,NULL); T("P4 rc=%d devices=%u\n",r,n); if(r||!n)return 1;
  VkPhysicalDevice pd; n=1; vkEnumeratePhysicalDevices(inst,&n,&pd);
  VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd,&props);
  T("P5 name=%s api=%u.%u\n",props.deviceName,VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion));
  n=0; vkGetPhysicalDeviceQueueFamilyProperties(pd,&n,NULL);
  VkQueueFamilyProperties fams[8]; if(n>8)n=8; vkGetPhysicalDeviceQueueFamilyProperties(pd,&n,fams);
  T("P6 fams=%u flags0=0x%x\n",n,fams[0].queueFlags);
  float pr=1.0f;
  VkDeviceQueueCreateInfo q; memset(&q,0,sizeof q); q.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO; q.queueFamilyIndex=0; q.queueCount=1; q.pQueuePriorities=&pr;
  VkDeviceCreateInfo d; memset(&d,0,sizeof d); d.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO; d.queueCreateInfoCount=1; d.pQueueCreateInfos=&q;
  VkDevice dev=NULL; r=vkCreateDevice(pd,&d,NULL,&dev); T("P6b rc=%d dev=%p\n",r,(void*)dev); if(r)return 1;
  VkQueue queue=NULL; vkGetDeviceQueue(dev,0,0,&queue);
  VkCommandPoolCreateInfo pc2; memset(&pc2,0,sizeof pc2); pc2.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO; pc2.queueFamilyIndex=0;
  VkCommandPool pool; r=vkCreateCommandPool(dev,&pc2,NULL,&pool); T("P7 pool rc=%d\n",r); if(r)return 1;
  VkCommandBufferAllocateInfo ba; memset(&ba,0,sizeof ba); ba.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO; ba.commandPool=pool; ba.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ba.commandBufferCount=1;
  VkCommandBuffer cb; r=vkAllocateCommandBuffers(dev,&ba,&cb); T("P7 alloc rc=%d\n",r); if(r)return 1;
  VkCommandBufferBeginInfo bb; memset(&bb,0,sizeof bb); bb.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  r=vkBeginCommandBuffer(cb,&bb); if(!r)vkEndCommandBuffer(cb); T("P7 be rc=%d\n",r); if(r)return 1;
  VkFenceCreateInfo fc; memset(&fc,0,sizeof fc); fc.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
  VkFence fence; r=vkCreateFence(dev,&fc,NULL,&fence); if(r)return 1;
  VkSubmitInfo s; memset(&s,0,sizeof s); s.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO; s.commandBufferCount=1; s.pCommandBuffers=&cb;
  r=vkQueueSubmit(queue,1,&s,fence); T("P7 submit rc=%d\n",r); if(r)return 1;
  r=vkWaitForFences(dev,1,&fence,1,5000000000ull); T("P7 fence rc=%d\n",r);
  vkDeviceWaitIdle(dev);
  T("X86-ON-MTK-GPU-CHAIN-OK\n");
  return 0;
}
