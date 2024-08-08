#include "key_value_store.cu"
#include <cuda.h>
#include <cuda_runtime_api.h>
#include "gdrapi.h"
#include "gdrcopy_common.hpp"
#include <curand.h>
#include <curand_kernel.h>
#include <algorithm>

// Customizable definitions
#ifndef NUM_KEYS
#define NUM_KEYS 512
#endif
#ifndef VALUE_SIZE
#define VALUE_SIZE 1024
#endif
#define DATA_ARR_SIZE (VALUE_SIZE / sizeof(int))
#define NUM_ITERATIONS 10
#define DEFAULT_NUM_THREAD_BLOCKS 70
#define DEFAULT_W_MODE "d"
#define DEFAULT_R_KERNEL "sync"
#define NUM_THREADS_PER_THREAD_BLOCK 512
#define CONCURRENT_COUNT 10

// Constant definitions
#define GET_START_ID NUM_ITERATIONS
#define GET_END_ID 2*NUM_ITERATIONS-1

struct UserResources {
    int key;
    unsigned int keySize = sizeof(int);
    unsigned int buffSize = sizeof(int) * DATA_ARR_SIZE;
    uint idx = 0;
    KVStatusType KVStatus[NUM_KEYS] = {KVStatusType::SUCCESS};
    int multiKey[NUM_KEYS]; // Array of key values
    int* keys[NUM_KEYS]; // Array of key ptrs - point to the values in multiKey
    int* buffs[NUM_KEYS];
    int dataBuffers[NUM_KEYS][DATA_ARR_SIZE];

    GPUMultiBufferHandle arrOfUserMultiBuffer[CONCURRENT_COUNT]; 
    GPUMultiBufferHandle arrOfUserKVStatusArr[CONCURRENT_COUNT];

    UserResources(){
        // Set by user
        size_t buffer_size_in_bytes = DATA_ARR_SIZE * sizeof(int);
        size_t num_buffers = NUM_KEYS;

        for (size_t i = 0; i < CONCURRENT_COUNT; i++)
        {
            cudaGPUMultiBufferAlloc(arrOfUserMultiBuffer[i], num_buffers, buffer_size_in_bytes);
            cudaGPUMultiBufferAlloc(arrOfUserKVStatusArr[i], num_buffers, sizeof(KVStatusType));
        }
        
    }

    ~UserResources(){
        for (size_t i = 0; i < CONCURRENT_COUNT; i++)
        {
            cudaGPUMultiBufferFree(arrOfUserMultiBuffer[i]);
            cudaGPUMultiBufferFree(arrOfUserKVStatusArr[i]);
        }
    }

};

__global__
void ResetIndex(UserResources* d_userResources){
    int blockIndex = blockIdx.x;
    d_userResources[blockIndex].idx = 0;
}

__global__
void InitData(UserResources* d_userResources){
    int tid = THREAD_ID;
    
    BEGIN_THREAD_ZERO {
        for (int j = 0; j < NUM_KEYS; j++)    
        {
            int blockIndex = blockIdx.x;          
            int *shuffledArray = d_userResources[blockIndex].dataBuffers[j];
            uint64_t seed = 0;

            for (int i = 0; i < DATA_ARR_SIZE; ++i) {
                shuffledArray[i] = i;
            }
            curandState_t state;
            curand_init(seed, 0, 0, &state); // Initialize CUDA random number generator

            // Shuffle the array using Fisher-Yates shuffle algorithm
            for (int i = DATA_ARR_SIZE - 1; i > 0; --i) {
                int j = curand(&state) % (i + 1);
                int temp = shuffledArray[i];
                shuffledArray[i] = shuffledArray[j];
                shuffledArray[j] = temp;
            }
        }
    } END_THREAD_ZERO
}

__device__
void check_wrong_answer(int* actual_answer_buf, int expected_answer, int &wrong_answers) {
    int tid = threadIdx.z * blockDim.y * blockDim.x 
        + threadIdx.y * blockDim.x 
        + threadIdx.x;
    BEGIN_THREAD_ZERO {
        if (actual_answer_buf[0] != expected_answer){
            wrong_answers++;
            int blockIndex = blockIdx.x;
            printf("-----------------\n");
            printf("--- Block %d: wrong answers: %d\n", blockIndex, wrong_answers);
            printf("--- actual_answer_buf[0] = %d\n", actual_answer_buf[0]);
            printf("--- expected_answer = %d\n", expected_answer);
            printf("-----------------\n");
        }
    } END_THREAD_ZERO
}

__global__
void async_read_kernel_3phase(KeyValueStore *kvStore, UserResources* d_userResources, const int numIterations) {    
    int blockIndex = blockIdx.x;
    int tid = threadIdx.z * blockDim.y * blockDim.x 
                    + threadIdx.y * blockDim.x 
                    + threadIdx.x;
                    
    UserResources &userResources = d_userResources[blockIndex];
#ifdef CHECK_WRONG_ANSWERS
    int wrong_answers = 0;
#endif
    unsigned int ticket_arr[CONCURRENT_COUNT]; // TODO guy keep it local memory?

    while (userResources.idx < CONCURRENT_COUNT){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
            for (int j = 0; j < NUM_KEYS; j++) {
                userResources.multiKey[j] = userResources.idx + 
                        blockIndex * numIterations +
                        j * gridDim.x * numIterations;
                userResources.keys[j] = &userResources.multiKey[j];
            }  
        } END_THREAD_ZERO
        kvStore->KVAsyncGetInitiateD((void**)userResources.keys, sizeof(int), userResources.arrOfUserMultiBuffer[userResources.idx % CONCURRENT_COUNT], sizeof(int) * DATA_ARR_SIZE, userResources.arrOfUserKVStatusArr[userResources.idx % CONCURRENT_COUNT], NUM_KEYS, &ticket_arr[userResources.idx % CONCURRENT_COUNT]);
    }
    
    while (userResources.idx < numIterations){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
            for (int j = 0; j < NUM_KEYS; j++) {
                userResources.multiKey[j] = userResources.idx + 
                        blockIndex * numIterations +
                        j * gridDim.x * numIterations;
                userResources.keys[j] = &userResources.multiKey[j];
            }
        } END_THREAD_ZERO
        kvStore->KVAsyncGetFinalizeD(ticket_arr[(userResources.idx - CONCURRENT_COUNT) % CONCURRENT_COUNT]);
#ifdef CHECK_WRONG_ANSWERS
        for (size_t i = 0; i < NUM_KEYS; i++)
        {
            check_wrong_answer((int*) userResources.arrOfUserMultiBuffer[(userResources.idx - CONCURRENT_COUNT) % CONCURRENT_COUNT].getDevicePtrSingleBuffer(i), userResources.idx - CONCURRENT_COUNT, wrong_answers);
        }
#endif
        kvStore->KVAsyncGetInitiateD((void**)userResources.keys, sizeof(int), userResources.arrOfUserMultiBuffer[userResources.idx % CONCURRENT_COUNT], sizeof(int) * DATA_ARR_SIZE, userResources.arrOfUserKVStatusArr[userResources.idx % CONCURRENT_COUNT], NUM_KEYS, &ticket_arr[userResources.idx % CONCURRENT_COUNT]);
    }
    
    while (userResources.idx < numIterations + CONCURRENT_COUNT){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
        } END_THREAD_ZERO
        kvStore->KVAsyncGetFinalizeD(ticket_arr[(userResources.idx - CONCURRENT_COUNT) % CONCURRENT_COUNT]);
#ifdef CHECK_WRONG_ANSWERS
        for (size_t i = 0; i < NUM_KEYS; i++)
        {
            check_wrong_answer((int*) userResources.arrOfUserMultiBuffer[(userResources.idx - CONCURRENT_COUNT) % CONCURRENT_COUNT].getDevicePtrSingleBuffer(i), userResources.idx - CONCURRENT_COUNT, wrong_answers);
        }
#endif
    }
}

__global__
void async_read_kernel(KeyValueStore *kvStore, UserResources* d_userResources, const int numIterations) {    
    int blockIndex = blockIdx.x;
    int tid = threadIdx.z * blockDim.y * blockDim.x 
                    + threadIdx.y * blockDim.x 
                    + threadIdx.x;
                    
    UserResources &userResources = d_userResources[blockIndex];
#ifdef CHECK_WRONG_ANSWERS
    int wrong_answers = 0;
#endif
    unsigned int ticket_arr[CONCURRENT_COUNT]; // TODO guy keep it local memory?

    while (userResources.idx < CONCURRENT_COUNT){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
            for (int j = 0; j < NUM_KEYS; j++) {
                userResources.multiKey[j] = userResources.idx + 
                        blockIndex * numIterations +
                        j * gridDim.x * numIterations;
                userResources.keys[j] = &userResources.multiKey[j];
            }  
        } END_THREAD_ZERO
        kvStore->KVAsyncGetInitiateD((void**)userResources.keys, 
        sizeof(int), 
        userResources.arrOfUserMultiBuffer[userResources.idx % CONCURRENT_COUNT], 
        sizeof(int) * DATA_ARR_SIZE, 
        userResources.arrOfUserKVStatusArr[userResources.idx % CONCURRENT_COUNT], 
        NUM_KEYS, 
        &ticket_arr[userResources.idx % CONCURRENT_COUNT]);
    }

    BEGIN_THREAD_ZERO {
        userResources.idx = 0; // TODO guy DELETE?
    } END_THREAD_ZERO

    while (userResources.idx < CONCURRENT_COUNT){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
        } END_THREAD_ZERO
        kvStore->KVAsyncGetFinalizeD(ticket_arr[(userResources.idx) % CONCURRENT_COUNT]);
#ifdef CHECK_WRONG_ANSWERS
        for (size_t i = 0; i < NUM_KEYS; i++)
        {
            check_wrong_answer((int*) userResources.arrOfUserMultiBuffer[(userResources.idx) % CONCURRENT_COUNT].getDevicePtrSingleBuffer(i), userResources.idx, wrong_answers);
        }
#endif
    }
}

__global__
void read_kernel(KeyValueStore *kvStore, UserResources* d_userResources, const int numIterations) {    
    int blockIndex = blockIdx.x;
    int tid = THREAD_ID;
                    
    UserResources &userResources = d_userResources[blockIndex];
#ifdef CHECK_WRONG_ANSWERS
    int wrong_answers = 0;
#endif

#ifdef MEASURE_RW_LOOPS
    BEGIN_THREAD_ZERO {
        userResources.idx = 0;
        clock_t start2, end2;
        start2 = clock();
    } END_THREAD_ZERO
#endif
    // Send multiget requests after multiput requests
    while (userResources.idx < numIterations){
        BEGIN_THREAD_ZERO {
            userResources.idx++;
            for (int i = 0; i < NUM_KEYS; i++) {
                userResources.multiKey[i] = userResources.idx + 
                        blockIndex * numIterations +
                        i * gridDim.x * numIterations;
                userResources.keys[i] = &userResources.multiKey[i];
            }  
        } END_THREAD_ZERO

        kvStore->KVMultiGetD((void**)userResources.keys, sizeof(int), (void**)userResources.buffs, sizeof(int) * DATA_ARR_SIZE, userResources.KVStatus, NUM_KEYS);
#ifdef CHECK_WRONG_ANSWERS
        for (size_t i = 0; i < NUM_KEYS; i++)
        {
            check_wrong_answer((int*) userResources.buffs[i], userResources.idx, wrong_answers);
        }
#endif
    }

#ifdef MEASURE_RW_LOOPS
    BEGIN_THREAD_ZERO {
        end2 = clock();
        clock_t elapsedCycles2 = end2 - start2;
        printf("Total get clocks = %ld\n", (long int)elapsedCycles2);
    } END_THREAD_ZERO
#endif
}

__global__
void write_kernel(KeyValueStore *kvStore, UserResources* d_userResources, const int numIterations) {    
    int blockIndex = blockIdx.x;
    int tid = THREAD_ID;
                    
    UserResources &userResources = d_userResources[blockIndex];

#ifdef MEASURE_RW_LOOPS
    clock_t start1, end1, start2, end2;
    BEGIN_THREAD_ZERO {    
        start1 = clock();
    } END_THREAD_ZERO
#endif
    // Send multiput requests 
    while (userResources.idx < numIterations){       
        BEGIN_THREAD_ZERO {
            userResources.idx++;
            for (int i = 0; i < NUM_KEYS; i++) {
                userResources.dataBuffers[i][0] = userResources.idx;
                userResources.buffs[i] = userResources.dataBuffers[i];
                userResources.multiKey[i] = userResources.idx + 
                        blockIndex * numIterations +
                        i * gridDim.x * numIterations;
                userResources.keys[i] = &userResources.multiKey[i];
            }        
        } END_THREAD_ZERO

        kvStore->KVMultiPutD((void**)userResources.keys, sizeof(int), (void**)userResources.buffs, sizeof(int) * DATA_ARR_SIZE, userResources.KVStatus, NUM_KEYS);
    }
    BEGIN_THREAD_ZERO {
#ifdef MEASURE_RW_LOOPS
    end1 = clock();
    clock_t elapsedCycles1 = end1 - start1;
    printf("Total put clocks = %ld\n", (long int)elapsedCycles1);
#endif
    }
}

void checkCPUCoreAvailability(int numThreadBlocks) {
    const int numCPUCores = sysconf(_SC_NPROCESSORS_ONLN);

    if (numCPUCores < numThreadBlocks) {
        std::cerr << "Error: CPU does not have the required number of cores." << std::endl
                  << "Available CPU cores: " << numCPUCores << std::endl
                  << "Required CPU cores: " << numThreadBlocks << std::endl;
        exit(EXIT_FAILURE);
    }
}

template<typename Func>
void sync_and_measure_time(Func&& func, const std::string& funcName, int numThreadBlocks) {
    std::cout << "---------------------------------------" << std::endl;
    std::cout << "Starting kernel run (" << funcName << ")..." << std::endl;
    auto start = std::chrono::high_resolution_clock::now();
    // Execute the passed function (kernel launch)
    func();

    CUDA_ERRCHECK(cudaDeviceSynchronize());
    auto stop = std::chrono::high_resolution_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::duration<double>>(stop - start).count();
    // std::cout << "Kernel run finished: " << std::fixed << std::setprecision(2) << duration << " seconds" << std::endl;
   
    uint64_t ios = numThreadBlocks * NUM_KEYS * NUM_ITERATIONS;
    uint64_t data = ios * VALUE_SIZE;
    double bandwidth = (((double)data)/duration)/(1000ULL*1000ULL*1000ULL);
    double iops = ((double)ios)/duration;
 
    std::cout << std::dec << "Elapsed Time (second): " << std::fixed << std::setprecision(2) << duration << std::endl;
    std::cout << "Effective Bandwidth (GB/s): " << bandwidth << std::endl;
    std::cout << "IOPS: " << iops << std::endl;
    std::cout << "---------------------------------------" << std::endl;
}

void appPutHCalls(int numThreadBlocks, KeyValueStore *kvStore){
    int numIterations = NUM_ITERATIONS;

    KVStatusType KVStatus[NUM_KEYS] = {KVStatusType::SUCCESS};
    int multiKey[NUM_KEYS]; // Array of key values
    int* keys[NUM_KEYS]; // Array of key ptrs - point to the values in multiKey
    int* buffs[NUM_KEYS];
    int dataBuffers[NUM_KEYS][DATA_ARR_SIZE];

    for (int j = 0; j < NUM_KEYS; j++) {
        int *shuffledArray = dataBuffers[j];
        unsigned int seed = (unsigned int)time(NULL) + j;  // Use time as seed, offset by j
        
        // Initialize the array
        for (int i = 0; i < DATA_ARR_SIZE; ++i) {
            shuffledArray[i] = i;
        }
        
        // Seed the random number generator
        srand(seed);
        
        // Shuffle the array using Fisher-Yates shuffle algorithm
        for (int i = DATA_ARR_SIZE - 1; i > 0; --i) {
            int k = rand() % (i + 1);
            int temp = shuffledArray[i];
            shuffledArray[i] = shuffledArray[k];
            shuffledArray[k] = temp;
        }
    }


    for (int blockIndex = 0; blockIndex < numThreadBlocks; blockIndex++)
    {    
        int idx = 0;
        while (idx < numIterations){       
            for (int i = 0; i < NUM_KEYS; i++) {
                dataBuffers[i][0] = idx;
                buffs[i] = dataBuffers[i];
                multiKey[i] = idx + 
                        blockIndex * numIterations +
                        i * numThreadBlocks * numIterations;
                keys[i] = &multiKey[i];
            }        

            // kvStore->KVMultiPutH((void**)keys, sizeof(int), (void**)buffs, sizeof(int) * DATA_ARR_SIZE, KVStatus, NUM_KEYS);
            for (int i = 0; i < NUM_KEYS; i++){
                kvStore->KVPutH(keys[i], sizeof(int), buffs[i], sizeof(int) * DATA_ARR_SIZE, KVStatus[i]);
            }
            idx++;
        }
    }
}

int main(int argc, char* argv[]) {
    int numThreadBlocks = DEFAULT_NUM_THREAD_BLOCKS;
    std::string wMode = DEFAULT_W_MODE;
    std::string rKernel = DEFAULT_R_KERNEL;
    for (int i = 1; i < argc; ++i) {
        if ((strcmp(argv[i], "--tb") == 0 || strcmp(argv[i], "--thread-blocks") == 0) && i + 1 < argc) {
            numThreadBlocks = std::atoi(argv[++i]);
        } else if ((strcmp(argv[i], "--w") == 0 || strcmp(argv[i], "--write") == 0) && i + 1 < argc) {
            wMode = argv[++i];
            std::transform(wMode.begin(), wMode.end(), wMode.begin(), [](unsigned char c){ return std::tolower(c); });
            if (wMode == "host" || wMode == "h")
                wMode = "h";
            else if (wMode == "device" || wMode == "d")
                wMode = "d";
            else{
                std::cout << "Write mode unavailable, choose h (host) or d (device). Using default value " << wMode << std::endl;
            }
        }
        else if ((strcmp(argv[i], "--rk") == 0 || strcmp(argv[i], "--read-kernel") == 0) && i + 1 < argc) {
            rKernel = argv[++i];
            std::transform(rKernel.begin(), rKernel.end(), rKernel.begin(), [](unsigned char c){ return std::tolower(c); });
            if (rKernel == "sync")
                rKernel = "sync";
            else if (rKernel == "async")
                rKernel = "async";
            else{
                std::cout << "Read kernel unavailable, choose sync or async. Using default value " << rKernel << std::endl;
            }
        }
    }
    //checkCPUCoreAvailability(numThreadBlocks);
    const int blockSize = NUM_THREADS_PER_THREAD_BLOCK;
    std::cout << "---------------------------------------" << std::endl;
    std::cout << "Settings:" << std::endl;
    std::cout << "Using " << numThreadBlocks << " thread blocks." << std::endl;
    std::cout << "Block size: " << blockSize << " threads per block." << std::endl;
    std::cout << "Write mode: " << wMode << std::endl;
    std::cout << "Read Kernel: " << rKernel << std::endl;
    std::cout << "NUM_ITERATIONS: " << NUM_ITERATIONS << std::endl;
    std::cout << "CONCURRENT_COUNT: " << CONCURRENT_COUNT << std::endl;
    std::cout << "NUM_KEYS: " << NUM_KEYS << std::endl;
    std::cout << "DATA_ARR_SIZE: " << DATA_ARR_SIZE << std::endl;
    std::cout << "---------------------------------------" << std::endl;

    KVMemHandle kvMemHandle;

    // Allocate pinned memory accessible by both CPU and GPU for a KeyValueStore instance.
    // Construct a KeyValueStore object in the allocated memory with specified thread blocks and block size.
    KeyValueStore *kvStore;
    CUDA_ERRCHECK(cudaHostAlloc((void **)&kvStore, sizeof(KeyValueStore), cudaHostAllocMapped));
    try {
        new (kvStore) KeyValueStore(numThreadBlocks, blockSize, DATA_ARR_SIZE*sizeof(int), NUM_KEYS, sizeof(int), kvMemHandle);
    }
    catch (const string& e) {
        std::cerr << e.c_str() << std::endl;
        CUDA_ERRCHECK(cudaFreeHost(kvStore));
        return 1;
    }

    // Open the kvStore database with the memory handle, enabling subsequent put and get calls.
    ERRCHECK(kvStore->KVOpenDB(kvMemHandle));

    // Allocate and initialize device memory for UserResources from host, preparing for numThreadBlocks worth of data.
    // The contents of these resources are set by the user and are dependant on the application.
    UserResources* d_userResources;
    UserResources* h_userResourcesTemp = new UserResources[numThreadBlocks];
    CUDA_ERRCHECK(cudaMalloc((void**)&d_userResources, numThreadBlocks * sizeof(UserResources)));
    CUDA_ERRCHECK(cudaMemcpy(d_userResources, h_userResourcesTemp, numThreadBlocks * sizeof(UserResources), cudaMemcpyHostToDevice)); 


    if (wMode == "h")
        appPutHCalls(numThreadBlocks, kvStore);
    else if (wMode == "d"){
        // Initialize the input data buffers with random data
        InitData<<<numThreadBlocks, 1>>>(d_userResources);
        CUDA_ERRCHECK(cudaDeviceSynchronize());

        sync_and_measure_time([&]() {
            write_kernel<<<numThreadBlocks, blockSize>>>(kvStore, d_userResources, NUM_ITERATIONS);
        }, "write_kernel", numThreadBlocks);
    }

    // Reset user resources idx before running a second kernel
    ResetIndex<<<numThreadBlocks, 1>>>(d_userResources);
    CUDA_ERRCHECK(cudaDeviceSynchronize());

    if (rKernel == "sync"){
        sync_and_measure_time([&]() {
            read_kernel<<<numThreadBlocks, blockSize>>>(kvStore, d_userResources, NUM_ITERATIONS);
        }, "read_kernel", numThreadBlocks);
    }
    else if (rKernel == "async"){
        sync_and_measure_time([&]() {
            async_read_kernel_3phase<<<numThreadBlocks, blockSize>>>(kvStore, d_userResources, NUM_ITERATIONS);
        }, "async_read_kernel_3phase", numThreadBlocks);
    }

    // GPU memory free:
    CUDA_ERRCHECK(cudaFree(d_userResources));

    delete[] h_userResourcesTemp;
    ERRCHECK(kvStore->KVCloseDB(kvMemHandle));
#ifndef XDP_ON_HOST
    ERRCHECK(kvStore->KVDeleteDB(kvMemHandle));
#endif
    kvStore->~KeyValueStore();
    CUDA_ERRCHECK(cudaFreeHost(kvStore));

    return 0;
}