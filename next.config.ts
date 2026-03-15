import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: 'standalone',
  images: {
    remotePatterns: [
      // AWS S3 regional patterns
      {
        protocol: 'https',
        hostname: '**.s3.*.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      // Your specific S3 bucket
      {
        protocol: 'https',
        hostname: 'wassupchat.s3.ap-south-1.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      // Generic S3 patterns
      {
        protocol: 'https',
        hostname: 's3.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      {
        protocol: 'https',
        hostname: '*.s3.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      // S3 with region patterns
      {
        protocol: 'https',
        hostname: 's3-*.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      // Additional S3 patterns for different regions
      {
        protocol: 'https',
        hostname: 's3.*.amazonaws.com',
        port: '',
        pathname: '/**',
      },
      // MinIO local development
      {
        protocol: 'http',
        hostname: 'localhost',
        port: '9000',
        pathname: '/**',
      },
      // MinIO with any hostname (for production)
      {
        protocol: 'http',
        hostname: '**.minio',
        pathname: '/**',
      },
      {
        protocol: 'https',
        hostname: '**.minio',
        pathname: '/**',
      },
      // MinIO storage bucket
      {
        protocol: 'https',
        hostname: 'storage.theworklabs.cc',
        pathname: '/**',
      }
      ],
      },
      };

export default nextConfig;
