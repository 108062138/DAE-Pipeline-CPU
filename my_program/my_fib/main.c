#include <stdlib/stdio.h>   // for printf
#include <stdlib/stdlib.h> // for NULL and malloc
#include <hal/halt.h>       // for halting the CPU when done

int my_fib_v1(int i){
    if(i==1) return 1;
    if(i==2) return 1;
    return my_fib_v1(i-1) + my_fib_v1(i-2);
}

int my_fib_v2(int i, int* arr){
    if(i==1) return 1;
    if(i==2) return 1;
    if(arr[i]!=0) return arr[i];
    return my_fib_v2(i-1, arr) + my_fib_v2(i-2, arr);
}

int main(void){
    printf("[my boot] main entered\n");
    int n = 19;
    int mode = 1;
    int get_res = 0;
    int* arr = NULL;
    if(mode==2){
        arr = (int*)malloc((n+1) * sizeof(int));
        for(int i=0;i<=n;i++) arr[i] = 0;
        get_res = my_fib_v2(n, arr);
        free(arr);
    }else{
        get_res = my_fib_v1(n);
    }
    printf("calculated res: %d\n", get_res);
    halt(0);
}