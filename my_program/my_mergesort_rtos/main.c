#include <stdlib/stdio.h>
#include <hal/halt.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

extern void freertos_risc_v_trap_handler(void);

static void install_mtvec(void) {
    unsigned long handler = (unsigned long)&freertos_risc_v_trap_handler;
    configASSERT((handler & 0x3u) == 0);
    __asm__ volatile("csrw mtvec, %0" : : "r"(handler));
}

#define ARR_LEN 16
#define HALF (ARR_LEN / 2)

static int data[ARR_LEN] = {
    42, 7, 93, 3, 68, 25, 11, 80,
    55, 1, 74, 30, 99, 18, 62, 46
};

typedef struct {
    int *base;
    int len;
    QueueHandle_t q;
    const char *name;
} sorter_param;

static QueueHandle_t xLeftQueue, xRightQueue;

static void merge_halves(int *a, int *tmp, int lo, int mid, int hi) {
    int i = lo, j = mid, k = lo;
    while (i < mid && j < hi) tmp[k++] = (a[i] <= a[j]) ? a[i++] : a[j++];
    while (i < mid) tmp[k++] = a[i++];
    while (j < hi)  tmp[k++] = a[j++];
    for (i = lo; i < hi; i++) a[i] = tmp[i];
}

static void merge_sort(int *a, int *tmp, int lo, int hi) {
    if (hi - lo < 2) return;
    int mid = lo + (hi - lo) / 2;
    merge_sort(a, tmp, lo, mid);
    merge_sort(a, tmp, mid, hi);
    merge_halves(a, tmp, lo, mid, hi);
}

static void vTaskSorter(void *param) {
    sorter_param *p = (sorter_param *)param;
    int tmp[HALF];
    merge_sort(p->base, tmp, 0, p->len);
    printf("[%s] half sorted\n", p->name);
    for (int i = 0; i < p->len; i++) {
        while (xQueueSend(p->q, &p->base[i], portMAX_DELAY) == errQUEUE_FULL) {}
    }
    vTaskDelete(NULL);
}

static void print_array(const char *label, const int *a, int len) {
    printf("%s", label);
    for (int i = 0; i < len; i++) {
        printf(" %d", a[i]);
    }
    printf("\n");
}

// Streaming 2-way merge: pull from whichever queue holds the smaller head.
static void vTaskMerger(void *param) {
    (void)param;
    static int merged[ARR_LEN];
    int l = 0, r = 0, prev = 0;
    int l_left = HALF, r_left = HALF;
    int have_l = 0, have_r = 0;
    int ok = 1;
    for (int out = 0; out < ARR_LEN; out++) {
        if (!have_l && l_left > 0) {
            while (xQueueReceive(xLeftQueue, &l, portMAX_DELAY) != pdTRUE) {}
            have_l = 1;
            l_left--;
        }
        if (!have_r && r_left > 0) {
            while (xQueueReceive(xRightQueue, &r, portMAX_DELAY) != pdTRUE) {}
            have_r = 1;
            r_left--;
        }
        int v;
        if (have_l && (!have_r || l <= r)) {
            v = l;
            have_l = 0;
        } else {
            v = r;
            have_r = 0;
        }
        if (out > 0 && v < prev) ok = 0;
        merged[out] = v;
        printf("sorted[%d] = %d\n", out, v);
        prev = v;
    }
    print_array("after: ", merged, ARR_LEN);
    printf(ok ? "PASS mergesort\n" : "FAIL mergesort\n");
    halt(ok ? 0 : 1);
}

int main(void) {
    install_mtvec();
    printf("[boot] main entered\n");
    print_array("before:", data, ARR_LEN);

    static sorter_param left  = {.base = &data[0],    .len = HALF, .name = "L"};
    static sorter_param right = {.base = &data[HALF], .len = HALF, .name = "R"};

    xLeftQueue = xQueueCreate(4, sizeof(int));
    xRightQueue = xQueueCreate(4, sizeof(int));
    left.q = xLeftQueue;
    right.q = xRightQueue;

    xTaskCreate(vTaskSorter, "SortL", 512, &left, 2, NULL);
    xTaskCreate(vTaskSorter, "SortR", 512, &right, 2, NULL);
    xTaskCreate(vTaskMerger, "Merge", 512, NULL, 1, NULL);
    vTaskStartScheduler();
    halt(0);
    return 0;
}

// unused hooks
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
