/*

Sapporo 2 device kernels

Version 1.0
CUDA DoubleSingle kernels

*/

#pragma OPENCL EXTENSION cl_khr_fp64: enable
#pragma OPENCL EXTENSION cl_amd_fp64: enable



#define __syncthreads() barrier(CLK_LOCAL_MEM_FENCE)                                                                                                        
#define blockIdx_x  get_group_id(0)                                                                                                                         
#define blockIdx_y  get_group_id(1)                                                                                                                         
#define threadIdx_x get_local_id(0)                                                                                                                         
#define threadIdx_y get_local_id(1)                                                                                                                         
#define gridDim_x   get_num_groups(0)                                                                                                                       
#define gridDim_y   get_num_groups(1)                                                                                                                       
#define blockDim_x  get_local_size(0)                                                                                                                       
#define blockDim_y  get_local_size(1)  


//#include "include/defines.h"

#define NGB_PB 256

#define inout
#define __out


#if 0   /* use this one to compute accelerations in DS */
#define _GACCDS_
#endif

#if 0  /* use this one to compute potentiaal in DS as well */
#define _GPOTDS_
#endif

#ifdef _GACCDS_
struct ds64
{
  float2 val;
  __host__ __device__ ds64() {}
  __host__ __device__ ds64(float x) : val(make_float2(x, x)) {}
  __host__ __device__ ds64(double x) 
  {
    val.x = (float)x;
    val.y = (float)(x - (double)val.x);
  }
  __host__ __device__ ds64 operator+=(const float x) 
  {
    const float vx = val.x + x;
    const float vy = val.y - ((vx - val.x) - x);
    val = make_float2(vx, vy);
    return *this;
  }
  __host__ __device__ double to_double() const { return (double)val.x + (double)val.y; }
  __host__ __device__ float to_float() const { return (float)((double)val.x + (double)val.y);}
};

struct devForce
{
  ds64 x, y, z;   // 6
#ifdef _GPOTDS_
  ds64 w;          // 8
#else
  float w;         // 7
  int  iPad;        // 8
#endif
  __host__ __device__ devForce() {}
  __device__ devForce(const float v) : x(v), y(v), z(v), w(v) {}
  __device__ float4 to_float4() const
  {
#ifdef _GPOTDS_
    return (float4){x.to_float(), y.to_float(), z.to_float(), w.to_float()};
#else
    return (float4){x.to_float(), y.to_float(), z.to_float(), w};
#endif
  }
  __device__ double4 to_double4() const
  {
#ifdef _GPOTDS_
    return (double4){x.to_double(), y.to_double(), z.to_double(), w.to_double()};
#else
    return (double4){x.to_double(), y.to_double(), z.to_double(), (double)w};
#endif
  }
};

#else /* not _GACCDS_ */

struct devForce
{
  float x,y,z,w;
/*  __inline devForce() {}
  __inline devForce(const float v) : x(v), y(v), z(v), w(v) {}
  __inline float4 to_float4() const {return (float4){x,y,z,w};}
  __inline double4 to_double4() const {return (double4){x,y,z,w};}
*/
};

#endif



typedef float2 DS;  // double single;

typedef struct DS4 {
  DS x, y, z, w;
} DS4;
typedef struct DS2 {
  DS x, y;
} DS2;


__inline DS to_DS(double a) {
  DS b;
  b.x = (float)a;
  b.y = (float)(a - b.x);
  return b;
}

__inline double to_double(DS a) {
  double b;
  b = (double)((double)a.x + (double)a.y);
  return b;
}


// This function computes c = a + b.
__inline DS dsaddds(DS a, DS b) {
  // Compute dsa + dsb using Knuth's trick.
  float t1 = a.x + b.x;
  float e = t1 - a.x;
  float t2 = ((b.x - e) + (a.x - (t1 - e))) + a.y + b.y;
  
  // The result is t1 + t2, after normalization.
  DS c;
  c.x = e = t1 + t2;
  c.y = t2 - (e - t1);
  return c;
} // dsadd

// This function computes c = a + b.
__inline DS dsadd(DS a, float b) {
  // Compute dsa + dsb using Knuth's trick.
  float t1 = a.x + b;
  float e = t1 - a.x;
  float t2 = ((b - e) + (a.x - (t1 - e))) + a.y;
  
  // The result is t1 + t2, after normalization.
  DS c;
  c.x = e = t1 + t2;
  c.y = t2 - (e - t1);
  return c;
} // dsadd


#define CAST 1

// __inline float2 body_body_interaction(
__inline void body_body_interaction(
                                    inout struct devForce *acc_i, 
                                    inout float4 *jrk_i,
                                    inout float2  *ds2_min,     
                                    inout int   *n_ngb,
                                    inout __private int *ngb_list,
                                    const DS4     pos_i, 
                                    const float4  vel_i,
                                    const DS4     pos_j, 
                                    const float4  vel_j,
                                    //const float  EPS2,
                                    float  EPS2,
                                    const int iID
                                    ) {

  #if CAST
    const int jID   = (int)(pos_j.w.y);
  #else
    const int jID   = as_int(pos_j.w.y);
  #endif
//   if((jID == iID)) return;

  if (iID != jID)    /* assuming we always need ngb */
  {

    const float3 dr = {(pos_j.x.x - pos_i.x.x) + (pos_j.x.y - pos_i.x.y),
                      (pos_j.y.x - pos_i.y.x) + (pos_j.y.y - pos_i.y.y),
                      (pos_j.z.x - pos_i.z.x) + (pos_j.z.y - pos_i.z.y)};   // 3x3 = 9 FLOP
   

    const float ds2 = ((dr.x*dr.x) + dr.y*dr.y) + dr.z*dr.z;
#if 1
    (*ds2_min) = ((*ds2_min).x < ds2) ? (*ds2_min) : (float2){ds2, pos_j.w.y};


    /* WARRNING: In case of the overflow, the behaviour will be different from the original version */
    if (ds2 <= pos_i.w.x)
    {
      ngb_list[(*n_ngb) & (NGB_PB-1)] = jID;
      (*n_ngb)++;
    }

#endif

    float inv_ds = 0.0f;
    inv_ds = rsqrt(ds2+EPS2);
    //     inv_ds = (jID == iID) ? 0.0f : inv_ds; //451800

    const float mass   = pos_j.w.x;
    const float minvr1 = mass*inv_ds; 
    const float  invr2 = inv_ds*inv_ds; 
    const float minvr3 = minvr1*invr2;

    // 3*4 + 3 = 15 FLOP
    (*acc_i).x += minvr3 * dr.x;
    (*acc_i).y += minvr3 * dr.y;
    (*acc_i).z += minvr3 * dr.z;
    (*acc_i).w += (-1.0f)*minvr1;
    //(*acc_i).w += 1;
#if 1
    const float3 dv  =  {vel_j.x - vel_i.x, vel_j.y - vel_i.y, vel_j.z -  vel_i.z};
    const float drdv = (-3.0f) * (minvr3*invr2) * (((dr.x*dv.x) + dr.y*dv.y) + dr.z*dv.z);

    (*jrk_i).x += minvr3 * dv.x + drdv * dr.x;  
    (*jrk_i).y += minvr3 * dv.y + drdv * dr.y;
    (*jrk_i).z += minvr3 * dv.z + drdv * dr.z;
#endif
    // TOTAL 50 FLOP (or 60 FLOP if compared against GRAPE6)  
  }

}

/*
 *  blockDim.x = ni
 *  gridDim.x  = 16, 32, 64, 128, etc. 
 */ 

#define ajc(i, j) (i + blockDim_x*j)
__kernel
//__attribute__((reqd_work_group_size(256,1,1)))
//__attribute__((work_group_size_hint(256,1,1)))
void dev_evaluate_gravity(
                                     const          int        nj_total, 
                                     const          int        nj,
                                     const          int        ni_offset,                                   
                                     const __global double4    *pos_j, 
                                     const __global double4    *pos_i,
                                     __out __global double4    *acc_i,                                    
                                     const          double     EPS2_d,
                                     const __global double4    *vel_j,
                                     const __global int        *id_j,                                     
                                     const __global double4    *vel_i,
                                     __out __global double4    *jrk_i,
                                     __out __global int        *id_i,
                                     __out __global double     *ds2min_i,
                                     __out __global int        *ngb_count_i,
                                     __out __global int        *ngb_list,
                                           __local  DS4        *shared_pos) {


  const int tx = threadIdx_x;
  const int ty = threadIdx_y;
  const int bx =  blockIdx_x;
  const int Dim = blockDim_x*blockDim_y;

  const int gid = blockIdx_x*blockDim_x + threadIdx_x;

  __local float4 *shared_vel = (__local float4*)&shared_pos[Dim];


  int local_ngb_list[NGB_PB + 1];
  int n_ngb = 0;

  const float EPS2 = (float)EPS2_d;

  DS4 pos;
  pos.x = to_DS(pos_i[tx+ni_offset].x); 
  pos.y = to_DS(pos_i[tx+ni_offset].y);
  pos.z = to_DS(pos_i[tx+ni_offset].z);
  pos.w = to_DS(pos_i[tx+ni_offset].w);

  const int iID    = id_i[tx+ni_offset];
  const float4 vel = (float4){vel_i[tx+ni_offset].x, vel_i[tx+ni_offset].y, 
                              vel_i[tx+ni_offset].z, vel_i[tx+ni_offset].w};

  const float LARGEnum = 1.0e10f;

  float2  ds2_min2;
  ds2_min2.x = LARGEnum;
  #if CAST
    ds2_min2.y = (float)(-1);
  #else
    ds2_min2.y = as_float(-1);
  #endif
  int ngb_id = -1;

  struct devForce acc;
  acc.x = acc.y = acc.z = acc.w = 0.0f;
  float4   jrk = {0.0f, 0.0f, 0.0f, 0.0f};

  int tile = 0;
  int ni    = bx * (nj*blockDim_y) + nj*ty; //Default
  const int offy = blockDim_x*ty;


//    ni = 0;              //Test
//    int nend = nj_total;     //Test
  


//     for (int i = ni; i < nend; i += blockDim_x)        //Test
   for (int i = ni; i < ni+nj; i += blockDim_x)  //Default
  {
    const int addr = offy + tx;

    if (i + tx < nj_total) 
    {
      const double4 jp     = pos_j[i + tx];
      shared_pos[addr].x   = to_DS(jp.x);
      shared_pos[addr].y   = to_DS(jp.y);
      shared_pos[addr].z   = to_DS(jp.z);
      shared_pos[addr].w   = to_DS(jp.w);     
      #if CAST
        shared_pos[addr].w.y = (float)(id_j[i + tx]);
      #else
        shared_pos[addr].w.y = as_float(id_j[i + tx]);
      #endif
      shared_vel[addr]     = (float4){vel_j[i + tx].x, 
                                      vel_j[i + tx].y, 
                                      vel_j[i + tx].z, 
                                      vel_j[i + tx].w};
    } else {
      shared_pos[addr].x = (float2){LARGEnum, 0.0f};
      shared_pos[addr].y = (float2){LARGEnum, 0.0f};
      shared_pos[addr].z = (float2){LARGEnum, 0.0f};
      shared_pos[addr].w = (float2){0.0f,  -1.0f}; 
      shared_vel[addr]   = (float4){0.0f, 0.0f, 0.0f, 0.0f};
    }

    __syncthreads();

    const int j  = min(nj - tile*blockDim_x, blockDim_x);
    const int j1 = j & (-32);

#pragma unroll 32
    for (int k = 0; k < j1; k++) 
        body_body_interaction(
          &acc, &jrk, &ds2_min2, &n_ngb, local_ngb_list,
          pos, vel, 
          shared_pos[offy+k], 
          shared_vel[offy+k],
          EPS2, iID);

//No unroll here, AMD does not like it....
    for (int k = j1; k < j; k++) 
        body_body_interaction(
          &acc, &jrk, &ds2_min2, &n_ngb, local_ngb_list,
          pos, vel,
          shared_pos[offy+k],
          shared_vel[offy+k],
          EPS2, iID);

    __syncthreads();

    tile++;
  } //end while



  __local float4 *shared_acc = (__local float4*)&shared_pos[0];
  __local float4 *shared_jrk = (__local float4*)&shared_acc[blockDim_x*blockDim_y];
  __local int    *shared_ngb = (__local int*   )&shared_jrk[blockDim_x*blockDim_y];
  __local int    *shared_ofs = (__local int*   )&shared_ngb[blockDim_x*blockDim_y];
  __local float  *shared_ds  = (__local float* )&shared_ofs[blockDim_x*blockDim_y];

  float ds2_min = ds2_min2.x;
  jrk.w  = ds2_min2.y;

  const int addr = offy + tx;
//   shared_acc[addr] = acc.to_float4();
  shared_acc[addr].x = acc.x; shared_acc[addr].y = acc.y;
  shared_acc[addr].z = acc.z; shared_acc[addr].w = acc.w;
  shared_jrk[addr] = jrk;
  shared_ngb[addr] = n_ngb;
  shared_ofs[addr] = 0;
  shared_ds [addr] = ds2_min;
  __syncthreads();

  if (ty == 0)
  {
    for (int i = blockDim_x; i < Dim; i += blockDim_x)
    {
      const int addr = i + tx;
      float4 acc1 = shared_acc[addr];
      float4 jrk1 = shared_jrk[addr];
      float  ds1  = shared_ds [addr];

      acc.x += acc1.x;
      acc.y += acc1.y;
      acc.z += acc1.z;
      acc.w += acc1.w;

      jrk.x += jrk1.x;
      jrk.y += jrk1.y;
      jrk.z += jrk1.z;

      if (ds1  < ds2_min) 
      {
        jrk.w   = jrk1.w;
        ds2_min  = ds1;
      }

      shared_ofs[addr] = min(n_ngb, NGB_PB);
      n_ngb += shared_ngb[addr];
    }
      n_ngb  = min(n_ngb, NGB_PB);
  }
  __syncthreads();

  //TODO fill in nearest neighbour on the right spot!

  if (ty == 0) 
  {
    //Convert results to double and write
    const int addr = bx*blockDim_x + tx;
    ds2min_i[      addr]   = ds2_min;
    acc_i[         addr].x = acc.x; acc_i[         addr].y = acc.y;
    acc_i[         addr].z = acc.z; acc_i[         addr].w = acc.w;
    jrk_i[         addr] = (double4){jrk.x, jrk.y, jrk.z, jrk.w};
    ngb_count_i[   addr]   = n_ngb;
  }

  //Write the neighbour list
  {
    int offset  = threadIdx_x * gridDim_x*NGB_PB + blockIdx_x * NGB_PB;
    offset     += shared_ofs[addr];
    n_ngb       = shared_ngb[addr];
    for (int i = 0; i < n_ngb; i++) 
      ngb_list[offset + i] = local_ngb_list[i];
  }
}

/*
 *  blockDim.x = #of block in previous kernel
 *  gridDim.x  = ni
 */ 
__kernel void dev_reduce_forces(
                                __global double4 *acc_i_temp, 
                                __global double4 *jrk_i_temp,
                                __global double  *ds_i_temp,
                                __global int     *ngb_count_i_temp,
                                __global int     *ngb_list_i_temp,
                                __global double4 *result_i,
                                __global double  *ds_i,
                                __global int     *ngb_count_i,
                                __global int     *ngb_list,                                
                                         int     offset_ni_idx,
                                         int     ni_total,
                               __local  float4   *shared_acc ) {
  
//    extern __shared__ float4 shared_acc[];
  __local  float4 *shared_jrk = (__local float4*)&shared_acc[blockDim_x];
  __local  int    *shared_ngb = (__local int*   )&shared_jrk[blockDim_x];
  __local int    *shared_ofs  = (__local int*   )&shared_ngb[blockDim_x];
  __local float  *shared_ds   = (__local float* )&shared_ofs[blockDim_x];
  
  int index = threadIdx_x * gridDim_x + blockIdx_x;

  //Early out if we are a block for non existent particle
  if((blockIdx_x + offset_ni_idx) >= ni_total)
    return;

  //Convert the data to floats
  shared_acc[threadIdx_x] = (float4){acc_i_temp[index].x, acc_i_temp[index].y, acc_i_temp[index].z, acc_i_temp[index].w};
  shared_jrk[threadIdx_x] = (float4){jrk_i_temp[index].x, jrk_i_temp[index].y, jrk_i_temp[index].z, jrk_i_temp[index].w};
  shared_ds [threadIdx_x] = (float)ds_i_temp[index]; 

  shared_ngb[threadIdx_x] =  ngb_count_i_temp[index];
  shared_ofs[threadIdx_x] = 0;
         
  __syncthreads();


  int n_ngb = shared_ngb[threadIdx_x];
  if (threadIdx_x == 0) {
    float4 acc0 = shared_acc[0];
    float4 jrk0 = shared_jrk[0];
    float  ds0  = shared_ds [0];

    for (int i = 1; i < blockDim_x; i++) {
      acc0.x += shared_acc[i].x;
      acc0.y += shared_acc[i].y;
      acc0.z += shared_acc[i].z;
      acc0.w += shared_acc[i].w;

      jrk0.x += shared_jrk[i].x;
      jrk0.y += shared_jrk[i].y;
      jrk0.z += shared_jrk[i].z;

      if (shared_ds[i] < ds0) {
        ds0    = shared_ds[i];
        jrk0.w = shared_jrk[i].w;
      }

      shared_ofs[i] = min(n_ngb, NGB_PB);
      n_ngb += shared_ngb[i];

    }
    n_ngb = min(n_ngb, NGB_PB);

    #if CAST
      jrk0.w = (int)(jrk0.w);
    #else
      jrk0.w = as_int(jrk0.w);
    #endif

    //Store the results
    result_i       [blockIdx_x + offset_ni_idx]            = (double4){acc0.x, acc0.y, acc0.z, acc0.w};
    result_i       [blockIdx_x + offset_ni_idx + ni_total] = (double4){jrk0.x, jrk0.y, jrk0.z, jrk0.w};    
    ds_i        [blockIdx_x + offset_ni_idx] = ds0;
    ngb_count_i [blockIdx_x + offset_ni_idx] = n_ngb;
  }
  __syncthreads();

  //Compute the offset of where to store the data and where to read it from
  //Store is based on ni, where to read it from is based on thread/block
  int offset     = (offset_ni_idx + blockIdx_x)  * NGB_PB + shared_ofs[threadIdx_x];
  int offset_end = (offset_ni_idx + blockIdx_x)  * NGB_PB + NGB_PB;
  int ngb_index  = threadIdx_x * NGB_PB + blockIdx_x * NGB_PB*blockDim_x;


  n_ngb = shared_ngb[threadIdx_x];
  __syncthreads();
  for (int i = 0; i < n_ngb; i++)
  {
    if (offset + i < offset_end){
        ngb_list[offset + i] = ngb_list_i_temp[ngb_index + i];
    }
  }

}


/*
 * Function that moves the (changed) j-particles
 * to the correct address location.
*/
__kernel void dev_copy_particles(int nj, 
                                 __global             double4   *pos_j, 
                                 __global             double4   *pos_j_temp,
                                 __global             int       *address_j,
                                 __global             double2   *t_j,
                                 __global             double4   *Ppos_j,
                                 __global             double4   *Pvel_j,
                                 __global             double4   *vel_j,
                                 __global             double4   *acc_j,
                                 __global             double4   *jrk_j,
                                 __global             int       *id_j,
                                 __global             double2   *t_j_temp,
                                 __global             double4   *vel_j_temp,
                                 __global             double4   *acc_j_temp,
                                 __global             double4   *jrk_j_temp,
                                  __global            int       *id_j_temp) {
//   int index = blockIdx_x * blockDim_x + threadIdx_x;
  const uint bid = blockIdx_y * gridDim_x + blockIdx_x;
  const uint tid = threadIdx_x;
  const uint index = bid * blockDim_x + tid;

  //Copy the changed particles
  if (index < nj)
  {
    t_j  [address_j[index]] = t_j_temp[index];

    Ppos_j[address_j[index]] = pos_j_temp[index];
     pos_j[address_j[index]] = pos_j_temp[index];

    Pvel_j[address_j[index]] = vel_j_temp[index];
     vel_j[address_j[index]] = vel_j_temp[ index];

    acc_j[address_j[index]]  = acc_j_temp[index];
    jrk_j[address_j[index]]  = jrk_j_temp[index];

    id_j[address_j[index]]   = id_j_temp[index];
  }
}

/*

Function to predict the particles
DS version

*/

__kernel void dev_predictor(int nj,
                              double  t_i_d,
                            __global  double2 *t_j,
                            __global  double4 *Ppos_j,
                            __global  double4 *Pvel_j,
                            __global  double4 *pos_j, 
                            __global  double4 *vel_j,
                            __global  double4 *acc_j,
                            __global  double4 *jrk_j) {
//   int index = blockIdx_x * blockDim_x + threadIdx_x;
  const uint bid = blockIdx_y * gridDim_x + blockIdx_x;
  const uint tid = threadIdx_x;
  const uint index = bid * blockDim_x + tid;
  
  if (index < nj) {

    //Convert the doubles to DS
    DS2 t;
    t.x = to_DS(t_j[index].x);
    t.y = to_DS(t_j[index].y);

    DS t_i;
    t_i = to_DS(t_i_d);

    DS4 pos;
    pos.x = to_DS(pos_j[index].x); pos.y = to_DS(pos_j[index].y);
    pos.z = to_DS(pos_j[index].z); pos.w = to_DS(pos_j[index].w);

    float4 vel = (float4){vel_j[index].x, vel_j[index].y, vel_j[index].z, vel_j[index].w};
    float4 acc = (float4){acc_j[index].x, acc_j[index].y, acc_j[index].z, acc_j[index].w};
    float4 jrk = (float4){jrk_j[index].x, jrk_j[index].y, jrk_j[index].z, jrk_j[index].w};
  
    float dt = (t_i.x - t.x.x) + (t_i.y - t.x.y);
    float dt2 = dt*dt/2.0f;
    float dt3 = dt2*dt/3.0f;
    
    pos.x  = dsadd(pos.x, vel.x * dt + acc.x * dt2 + jrk.x * dt3);
    pos.y  = dsadd(pos.y, vel.y * dt + acc.y * dt2 + jrk.y * dt3);
    pos.z  = dsadd(pos.z, vel.z * dt + acc.z * dt2 + jrk.z * dt3);

    vel.x += acc.x * dt + jrk.x * dt2;
    vel.y += acc.y * dt + jrk.y * dt2;
    vel.z += acc.z * dt + jrk.z * dt2;


    Ppos_j[index].x = to_double(pos.x); Ppos_j[index].y = to_double(pos.y);
    Ppos_j[index].z = to_double(pos.z); Ppos_j[index].w = to_double(pos.w);            

    Pvel_j[index] = (double4){vel.x, vel.y, vel.z, vel.w};
  }
  __syncthreads();
}

