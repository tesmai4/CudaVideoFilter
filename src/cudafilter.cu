#include "cudafilter.hpp"
#include <stdlib.h>
#include <string.h>
#include <cuda.h>
#include <cmath>
#include <stdio.h>
#include <assert.h>
#include <iostream>

#define THREADS_PER_DIM 32
#define CUDA_ERR_HANDLER(err) cudaErrorHandler(err, __FILE__, __LINE__)

static void cudaErrorHandler(cudaError_t err, const char *file, int line) {
   if(err != cudaSuccess) {
      std::cerr<<cudaGetErrorString(err)<<" on line "<<line<<" : "<<file<<std::endl;
      exit(EXIT_FAILURE);
   }
}

__device__ void convolutionFilter(Image image, Image result, Filter filter, int x, int y) {
   
   /*
   float3 bgr;

   //multiply every value of the filter with corresponding image pixel 
   for(int filterX = 0; filterX < filter.cols; filterX++) {
      for(int filterY = 0; filterY < filter.rows; filterY++) {
         int imageX = x - filter.cols / 2 + filterX;
         int imageY = y - filter.rows / 2 + filterY;
         if(imageX < 0 || imageX >= image.height ||
            imageY < 0 || imageY >= image.width)
            continue;
         
         float filterVal = filter[filterX][filterY];
         bgr.x += image.at(imageX, imageY, BLUE) * filterVal;
         bgr.y += image.at(imageX, imageY, GREEN) * filterVal;
         bgr.z += image.at(imageX, imageY, RED) * filterVal;
      } 
   }
   */
   
   
   
   float3 bgr = make_float3(0, 0, 0);

   __shared__ unsigned sharedImage[THREADS_PER_DIM][THREADS_PER_DIM * 3];
   int tx = threadIdx.x;
   int ty = threadIdx.y;

   sharedImage[ty][3*tx] = image.at(y, x, BLUE);
   sharedImage[ty][3*tx+1] = image.at(y, x, GREEN);
   sharedImage[ty][3*tx+2] = image.at(y, x, RED);

   __syncthreads();

  // multiply every value of the filter with corresponding image pixel 
   for(int filterX = 0; filterX < filter.cols; filterX++) {
      for(int filterY = 0; filterY < filter.rows; filterY++) {
         int shX = tx - filter.cols / 2 + filterX;
         int shY = ty - filter.rows / 2 + filterY;
         int glX = x - filter.cols / 2 + filterX;
         int glY = y - filter.rows / 2 + filterY;
         float filterVal = filter[filterX][filterY];

         if(glX < 0 || glX >= image.width ||
            glY < 0 || glY >= image.height)
            continue;

         if(shX >= THREADS_PER_DIM - 1 || shY >= THREADS_PER_DIM -1 || shX < 0 || shY < 0) {
            bgr.x += image.at(glY, glX, BLUE) * filterVal;
            bgr.y += image.at(glY, glX, GREEN) * filterVal;
            bgr.z += image.at(glY, glX, RED) * filterVal;
         }
         else {
            bgr.x += sharedImage[shY][3 * shX] * filterVal;//image.at(imageX, imageY, BLUE) * filterVal;
            bgr.y += sharedImage[shY][3 * shX + 1] * filterVal; //image.at(imageX, imageY, GREEN) * filterVal;
            bgr.z += sharedImage[shY][3 * shX + 2] * filterVal; //image.at(imageX, imageY, RED) * filterVal;
         }
      } 
   }
   


   //truncate values smaller than zero and larger than 255 
   result.at(y, x, BLUE) = min(max(int(filter.factor * bgr.x + filter.bias), 0), 255); 
   result.at(y, x, GREEN) = min(max(int(filter.factor * bgr.y + filter.bias), 0), 255); 
   result.at(y, x, RED) = min(max(int(filter.factor * bgr.z + filter.bias), 0), 255); 
}

__global__ void filterKernal(Image image, Image result, Filter filter) {
   int y = blockIdx.y * blockDim.y + threadIdx.y;
   int x = blockIdx.x * blockDim.x + threadIdx.x;

   if(y < image.height && x < image.width) {
      convolutionFilter(image, result, filter, x, y);
   }
}

CudaFilter::CudaFilter(Image image, Filter filter)
   :image(image), filter(filter) {}

CudaFilter::~CudaFilter() {
   for(int i=0; i<devmem.size(); i++)
      cudaFree(devmem.at(i));
}

void CudaFilter::toDevice(void **dev, void *host, int bytes) {
   CUDA_ERR_HANDLER(cudaMalloc(dev, bytes));
   CUDA_ERR_HANDLER(cudaMemcpy(*dev, host, bytes, cudaMemcpyHostToDevice));
   devmem.push_back(*dev);
}

void CudaFilter::toHost(void *host, void *dev, int bytes) {
   CUDA_ERR_HANDLER(cudaMemcpy(host, dev, bytes, cudaMemcpyDeviceToHost));
}

void CudaFilter::applyFilter() {
   Image devImage(image), devResult(image);
   Filter devFilter(filter);

   toDevice((void**)&devImage.data, image.data, image.size);
   toDevice((void**)&devResult.data, image.data, image.size);
   toDevice((void**)&devFilter.data, filter.data, filter.rows * filter.cols * sizeof(float));

   dim3 threadsPerBlock(THREADS_PER_DIM, THREADS_PER_DIM);
   dim3 blocksPerGrid((image.width + THREADS_PER_DIM - 1) / THREADS_PER_DIM, 
                      (image.height + THREADS_PER_DIM - 1) / THREADS_PER_DIM);

   filterKernal<<<blocksPerGrid, threadsPerBlock>>>(devImage, devResult, devFilter);
   CUDA_ERR_HANDLER(cudaGetLastError());

   assert(image.size == devResult.size);
   toHost(image.data, devResult.data, image.size);
}

float CudaFilter::operator() () {
   float ms;
   cudaEvent_t start, stop;
   cudaEventCreate(&start);
   cudaEventCreate(&stop);
   cudaEventRecord(start, 0);

   applyFilter();

   cudaEventRecord(stop, 0);
   cudaEventSynchronize(stop);
   cudaEventElapsedTime(&ms, start, stop);
   return ms;
}