#include <stdlib/stdio.h>
#include <hal/halt.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

extern void freertos_risc_v_trap_handler(void);

typedef struct {
    int n;
    int start_len;
} task_param;

static void install_mtvec(void) {
    unsigned long handler = (unsigned long)&freertos_risc_v_trap_handler;
    configASSERT((handler & 0x3u) == 0);
    __asm__ volatile("csrw mtvec, %0" : : "r"(handler));
}

static QueueHandle_t xFibQueue;

static void vTaskPrint(void* param){
    task_param* p = (task_param*)param;
    int n = p->n;
    int start_len = p->start_len;
    int result;
    for(int i=n - start_len + 1;i<=n;i++){
        while(xQueueReceive(xFibQueue, &result, portMAX_DELAY)!=pdTRUE){}
        printf("fib(%d) = %d\n", i, result);
    }
    halt(0);
}

static int my_fib(int i){
    if(i==1) return 1;
    if(i==2) return 1;
    return my_fib(i-1) + my_fib(i-2);
}

static void vTaskCompute(void *param){
    task_param* p = (task_param*)param;
    int n = p->n;
    int start_len = p->start_len; 
    for(int i=n-start_len+1;i<=n;i++){
        int result = my_fib(i);
        while(xQueueSend(xFibQueue, &result, portMAX_DELAY)==errQUEUE_FULL){}
    }
    vTaskDelete(NULL);
}

int main(void){
    install_mtvec();
    printf("[boot] main entered\n");
    
    static task_param params = {.n=7, .start_len = 3};
    int n = 7;
    xFibQueue = xQueueCreate(params.start_len, sizeof(int));
    xTaskCreate(vTaskCompute,"Compute", 512, &params, 2, NULL);
    xTaskCreate(vTaskPrint,"Print", 512, &params, 1, NULL);
    vTaskStartScheduler();
    halt(0);
    return 0;
}

// unuse hook
void vAssertCalled(const char *file, int line)
{
    (void)file; (void)line;
    halt(1);
}

void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    (void)xTask; (void)pcTaskName;
    halt(1);
}

void vApplicationMallocFailedHook(void)
{
    halt(1);
}