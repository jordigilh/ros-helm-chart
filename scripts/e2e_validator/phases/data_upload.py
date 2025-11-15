"""
Phase 4: Data Upload
=====================

Generate test data with Nise and upload to S3.
This creates predictable scenarios for financial validation.
"""

import os
import gzip
import json
from datetime import datetime, timedelta
from typing import Dict, List, Optional
import boto3

from ..clients.nise import NiseClient


class DataUploadPhase:
    """Phase 4: Generate and upload test data"""

    def __init__(self,
                 s3_client,
                 nise_client: NiseClient,
                 bucket: str = "cost-data",
                 report_name: str = "test-report",
                 report_prefix: str = "reports",
                 k8s_client=None):
        """Initialize data upload phase

        Args:
            s3_client: boto3 S3 client
            nise_client: NiseClient instance
            bucket: S3 bucket name
            report_name: Report name
            report_prefix: S3 key prefix (default: "reports/")
            k8s_client: KubernetesClient (for in-pod execution)
        """
        self.s3 = s3_client
        self.nise = nise_client
        self.bucket = bucket
        self.report_name = report_name
        self.report_prefix = report_prefix
        self.k8s = k8s_client

    def check_existing_data(self) -> Dict[str, any]:
        """Check if VALID test data already exists

        Validates that both manifest and CSV files are present and properly linked.

        Returns:
            Dict with:
                - exists: True if any files present
                - valid: True only if manifest + CSV files present and linked
                - count: Total object count
                - manifest: Manifest key if found
                - csv_files: List of CSV keys
                - error: Error message if S3 access fails
        """
        try:
            prefix_path = f'{self.report_prefix}/' if self.report_prefix else ''
            response = self.s3.list_objects_v2(
                Bucket=self.bucket,
                Prefix=f"{prefix_path}{self.report_name}/"
            )

            keys = [obj['Key'] for obj in response.get('Contents', [])]

            # Find manifest and CSV files
            manifests = [k for k in keys if k.endswith('-Manifest.json')]
            csv_files = [k for k in keys if k.endswith('.csv.gz') or k.endswith('.csv')]

            # Validate manifest if present
            valid_manifest = False
            if manifests:
                try:
                    manifest_obj = self.s3.get_object(
                        Bucket=self.bucket,
                        Key=manifests[0]
                    )
                    manifest_data = json.loads(manifest_obj['Body'].read())

                    # Check if manifest references existing CSV files
                    referenced_files = manifest_data.get('reportKeys', [])
                    valid_manifest = all(csv in keys for csv in referenced_files)

                except Exception as e:
                    print(f"    ⚠️  Manifest validation failed: {e}")
                    valid_manifest = False

            return {
                'exists': len(keys) > 0,
                'valid': valid_manifest and len(csv_files) > 0,
                'count': len(keys),
                'keys': keys,
                'manifest': manifests[0] if manifests else None,
                'csv_files': csv_files
            }

        except Exception as e:
            return {
                'exists': False,
                'valid': False,
                'count': 0,
                'error': str(e)
            }

    def generate_scenarios(self,
                          scenarios: List[str],
                          start_date: datetime,
                          end_date: datetime) -> Dict[str, str]:
        """Generate multiple test scenarios with Nise

        Args:
            scenarios: List of scenario names
            start_date: Start date
            end_date: End date

        Returns:
            Dict mapping scenario to local path
        """
        print(f"📊 Generating {len(scenarios)} test scenarios with Nise...")

        results = {}
        for scenario in scenarios:
            print(f"  - Generating '{scenario}'...")
            path = self.nise.generate_scenario(scenario, start_date, end_date)
            results[scenario] = path
            print(f"    ✓ Generated at {path}")

        return results

    def generate_basic_aws_data(self,
                               start_date: datetime,
                               end_date: datetime,
                               account_id: str = '123456789012') -> str:
        """Generate basic AWS CUR data

        Args:
            start_date: Start date
            end_date: End date
            account_id: AWS account ID

        Returns:
            Path to generated data
        """
        print("📊 Generating AWS CUR data with Nise...")
        print(f"  - Account: {account_id}")
        print(f"  - Period: {start_date.date()} to {end_date.date()}")

        # Generate with tags for testing
        path = self.nise.generate_aws_cur(
            start_date=start_date,
            end_date=end_date,
            account_id=account_id,
            tags=[
                'environment:production',
                'app:web-server',
                'cost-center:engineering'
            ]
        )

        print(f"  ✓ Data generated at {path}")
        return path

    def upload_nise_data(self,
                        data_path: str,
                        report_prefix: str = "") -> List[str]:
        """Upload Nise-generated data to S3

        Args:
            data_path: Path to Nise output directory
            report_prefix: S3 key prefix

        Returns:
            List of uploaded S3 keys
        """
        uploaded_keys = []

        # Find all files in Nise output
        for root, dirs, files in os.walk(data_path):
            for file in files:
                local_path = os.path.join(root, file)

                # Determine S3 key
                rel_path = os.path.relpath(local_path, data_path)
                s3_key = f"{self.report_name}/{report_prefix}{rel_path}"

                # Upload file
                print(f"  ⬆️  Uploading {file}...")
                with open(local_path, 'rb') as f:
                    self.s3.put_object(
                        Bucket=self.bucket,
                        Key=s3_key,
                        Body=f.read()
                    )

                uploaded_keys.append(s3_key)

        return uploaded_keys

    def create_manifest_for_nise_data(self,
                                     data_keys: List[str],
                                     start_date: datetime,
                                     end_date: datetime) -> str:
        """Create CUR manifest for Nise data

        Args:
            data_keys: List of S3 keys for data files
            start_date: Billing period start
            end_date: Billing period end

        Returns:
            Manifest S3 key
        """
        # Filter to only CSV files
        csv_keys = [k for k in data_keys if k.endswith('.csv.gz') or k.endswith('.csv')]

        manifest = {
            'reportId': f'{self.report_name}-{start_date.strftime("%Y%m%d")}',
            'reportName': self.report_name,
            'version': '1.0',
            'reportKeys': csv_keys,
            'billingPeriod': {
                'start': start_date.strftime('%Y-%m-%d'),
                'end': end_date.strftime('%Y-%m-%d')
            },
            'bucket': self.bucket,
            'reportPathPrefix': self.report_name,
            'timeGranularity': 'DAILY',
            'compression': 'GZIP',
            'format': 'textORcsv'
        }

        # Upload manifest
        period = f"{start_date.strftime('%Y%m%d')}-{end_date.strftime('%Y%m%d')}"
        manifest_key = f"{self.report_name}/{period}/{self.report_name}-Manifest.json"

        self.s3.put_object(
            Bucket=self.bucket,
            Key=manifest_key,
            Body=json.dumps(manifest, indent=2).encode('utf-8')
        )

        return manifest_key

    def run_full_scenario_upload(self,
                                scenarios: Optional[List[str]] = None,
                                days_back: int = 30) -> Dict[str, any]:
        """Run complete data generation and upload

        This is the main entry point for Phase 4.

        Args:
            scenarios: List of scenarios (default: basic scenarios)
            days_back: How many days of data to generate

        Returns:
            Upload results dict
        """
        if scenarios is None:
            # Default comprehensive scenario set
            scenarios = [
                'basic_compute',
                'storage_costs',
                'tagged_resources',
            ]

        end_date = datetime.now()
        start_date = end_date - timedelta(days=days_back)

        print("\n" + "="*60)
        print("Phase 4: Generate & Upload Test Data (Nise)")
        print("="*60)

        # Check existing data
        print("\n🔍 Checking for existing data...")
        existing = self.check_existing_data()

        if existing['exists']:
            print(f"  ⚠️  Found {existing['count']} existing objects")
            print("  Skipping generation (use --force to regenerate)")
            return {
                'skipped': True,
                'existing_count': existing['count']
            }

        # Generate scenarios
        print("\n📊 Generating test scenarios...")
        scenario_paths = self.generate_scenarios(scenarios, start_date, end_date)

        # Upload all scenario data
        print("\n⬆️  Uploading to S3...")
        all_keys = []

        for scenario, path in scenario_paths.items():
            print(f"\n  Uploading scenario: {scenario}")
            keys = self.upload_nise_data(path, report_prefix=f"{scenario}/")
            all_keys.extend(keys)
            print(f"  ✓ Uploaded {len(keys)} files")

        # Create manifest
        print("\n📝 Creating CUR manifest...")
        manifest_key = self.create_manifest_for_nise_data(
            all_keys, start_date, end_date
        )
        print(f"  ✓ Manifest: {manifest_key}")

        # Verify upload
        final_check = self.check_existing_data()

        result = {
            'success': True,
            'scenarios': scenarios,
            'files_uploaded': len(all_keys),
            'total_objects': final_check['count'],
            'manifest_key': manifest_key,
            'period': {
                'start': start_date.isoformat(),
                'end': end_date.isoformat()
            }
        }

        print("\n✅ Phase 4 Complete")
        print(f"  - Scenarios: {len(scenarios)}")
        print(f"  - Files uploaded: {len(all_keys)}")
        print(f"  - Total S3 objects: {final_check['count']}")

        return result

    def run_quick_upload(self,
                        days_back: int = 7) -> Dict[str, any]:
        """Quick single-scenario upload for fast testing

        Args:
            days_back: Days of data to generate

        Returns:
            Upload results
        """
        end_date = datetime.now()
        start_date = end_date - timedelta(days=days_back)

        print("\n🚀 Quick data upload (single scenario)...")

        # Generate basic AWS data only
        data_path = self.generate_basic_aws_data(start_date, end_date)

        # Upload
        print("\n⬆️  Uploading to S3...")
        keys = self.upload_nise_data(data_path)

        # Create manifest
        manifest_key = self.create_manifest_for_nise_data(
            keys, start_date, end_date
        )

        return {
            'success': True,
            'mode': 'quick',
            'files_uploaded': len(keys),
            'manifest_key': manifest_key
        }

    def upload_aws_cur_format(self,
                             start_date: datetime,
                             end_date: datetime,
                             force: bool = False) -> Dict[str, any]:
        """Generate and upload AWS CUR format data directly

        Creates proper AWS Cost and Usage Report format data and uploads
        to S3 using the external HTTPS endpoint (no need for in-pod execution).

        Args:
            start_date: Start date for data
            end_date: End date for data
            force: Force regeneration even if data exists

        Returns:
            Upload results dict
        """
        print("\n" + "="*60)
        print("Phase 4: Generate & Upload Test Data (AWS CUR Format)")
        print("="*60)

        # Check existing
        print("\n🔍 Checking for existing data...")
        existing = self.check_existing_data()

        # Surface S3 errors immediately
        if 'error' in existing:
            print(f"\n❌ S3 access error: {existing['error']}")
            print("   Check credentials and endpoint configuration")
            return {
                'success': False,
                'error': existing['error']
            }

        if existing['exists'] and not force:
            if not existing.get('valid'):
                print(f"  ⚠️  Found {existing['count']} objects but NO VALID MANIFEST")
                print(f"  💡 Run with --force to regenerate")
                return {
                    'skipped': True,
                    'reason': 'invalid_data',
                    'valid': False,
                    'existing_count': existing['count']
                }
            else:
                print(f"  ✅ Valid data exists:")
                print(f"     - Manifest: {existing['manifest']}")
                print(f"     - CSV files: {len(existing['csv_files'])}")
                print(f"  💡 Run with --force to regenerate")
                return {
                    'passed': True,
                    'skipped': True,
                    'reason': 'valid_data_exists',
                    'valid': True,
                    'existing_count': existing['count'],
                    'manifest': existing['manifest']
                }

        if existing['exists'] and force:
            print(f"  🗑️  Force mode: Deleting {existing['count']} existing objects...")
            for key in existing.get('keys', []):
                self.s3.delete_object(Bucket=self.bucket, Key=key)
                print(f"     - Deleted: {key}")
            print(f"  ✅ Cleaned existing data")

        # Format dates - use MASU's monthly date format (YYYYMMDD-YYYYMMDD)
        start_str = start_date.strftime('%Y-%m-%d')
        end_str = end_date.strftime('%Y-%m-%d')
        period = f"{start_date.strftime('%Y%m%d')}-{end_date.strftime('%Y%m%d')}"

        print(f"\n📊 Generating AWS CUR data ({start_str} to {end_str})...")
        print(f"   Period directory: {period} (MASU monthly format)")

        # Create AWS CUR format CSV data
        csv_data = f"""identity/LineItemId,identity/TimeInterval,bill/PayerAccountId,lineItem/UsageAccountId,lineItem/LineItemType,lineItem/UsageStartDate,lineItem/UsageEndDate,lineItem/ProductCode,lineItem/UsageType,lineItem/Operation,lineItem/ResourceId,lineItem/UsageAmount,lineItem/UnblendedRate,lineItem/UnblendedCost,lineItem/BlendedRate,lineItem/BlendedCost,product/instanceType,product/region,resourceTags/user:environment,resourceTags/user:app
1,{start_str}T00:00:00Z/{start_str}T01:00:00Z,123456789012,123456789012,Usage,{start_str}T00:00:00Z,{start_str}T01:00:00Z,AmazonEC2,BoxUsage:t3.medium,RunInstances,i-12345,24.0,0.0416,1.00,0.0416,1.00,t3.medium,us-east-1,production,web-server
2,{start_str}T00:00:00Z/{start_str}T01:00:00Z,123456789012,123456789012,Usage,{start_str}T00:00:00Z,{start_str}T01:00:00Z,AmazonEC2,BoxUsage:t3.large,RunInstances,i-67890,24.0,0.0832,2.00,0.0832,2.00,t3.large,us-east-1,development,database
3,{start_str}T00:00:00Z/{start_str}T01:00:00Z,123456789012,123456789012,Usage,{start_str}T00:00:00Z,{start_str}T01:00:00Z,AmazonEC2,EBS:VolumeUsage.gp3,CreateVolume,vol-12345,100.0,0.08,8.00,0.08,8.00,,,production,storage
4,{start_str}T00:00:00Z/{start_str}T01:00:00Z,123456789012,123456789012,Usage,{start_str}T00:00:00Z,{start_str}T01:00:00Z,AmazonEC2,EBS:VolumeUsage.gp3,CreateVolume,vol-67890,50.0,0.08,4.00,0.08,4.00,,,development,storage
5,{start_str}T00:00:00Z/{start_str}T01:00:00Z,123456789012,123456789012,Usage,{start_str}T00:00:00Z,{start_str}T01:00:00Z,AmazonS3,Requests-Tier1,GetObject,my-bucket,1000.0,0.0004,0.40,0.0004,0.40,,,production,data
"""

        # Compress CSV
        csv_gz = gzip.compress(csv_data.encode('utf-8'))

        # Upload CSV (clean S3 path without leading slash)
        # Add slash between prefix and report_name if prefix exists
        prefix_path = f'{self.report_prefix}/' if self.report_prefix else ''
        csv_key = f'{prefix_path}{self.report_name}/{period}/{self.report_name}-1.csv.gz'
        print(f"  ⬆️  Uploading CSV: {csv_key}")
        self.s3.put_object(
            Bucket=self.bucket,
            Key=csv_key,
            Body=csv_gz
        )

        # Create manifest (use AWS CUR manifest format with correct date format)
        import uuid as uuid_lib
        assembly_id = str(uuid_lib.uuid4())
        manifest = {
            'assemblyId': assembly_id,
            'reportId': 'test-report-001',
            'reportName': self.report_name,
            'version': '1.0',
            'reportKeys': [csv_key],
            'billingPeriod': {
                'start': start_date.strftime('%Y%m%dT000000.000Z'),
                'end': end_date.strftime('%Y%m%dT000000.000Z')
            },
            'bucket': self.bucket,
            'reportPathPrefix': self.report_name,
            'timeGranularity': 'DAILY',
            'compression': 'GZIP',
            'format': 'textORcsv'
        }

        # Upload manifest (clean S3 path without leading slash)
        manifest_key = f'{prefix_path}{self.report_name}/{period}/{self.report_name}-Manifest.json'
        print(f"  ⬆️  Uploading Manifest: {manifest_key}")
        self.s3.put_object(
            Bucket=self.bucket,
            Key=manifest_key,
            Body=json.dumps(manifest, indent=2).encode('utf-8')
        )

        # Copy to previous month's directory for MASU compatibility
        # MASU checks both current and previous month
        print(f"\n📋 Copying data to additional monthly paths for MASU discovery...")

        # Calculate previous month period
        if start_date.month == 1:
            prev_month_start = datetime(start_date.year - 1, 12, 1)
            prev_month_end = datetime(start_date.year, 1, 1)
        else:
            prev_month_start = datetime(start_date.year, start_date.month - 1, 1)
            prev_month_end = datetime(start_date.year, start_date.month, 1)

        prev_period = f"{prev_month_start.strftime('%Y%m%d')}-{prev_month_end.strftime('%Y%m%d')}"

        # Copy CSV to previous month
        prev_csv_key = f'{prefix_path}{self.report_name}/{prev_period}/{self.report_name}-1.csv.gz'
        try:
            self.s3.copy_object(
                Bucket=self.bucket,
                CopySource={'Bucket': self.bucket, 'Key': csv_key},
                Key=prev_csv_key
            )
            print(f"  ✓ Copied CSV to: {prev_csv_key}")
        except Exception as e:
            print(f"  ⚠️  Failed to copy CSV to previous month: {e}")

        # Copy manifest to previous month (update billingPeriod with correct AWS format)
        prev_assembly_id = str(uuid_lib.uuid4())
        prev_manifest = manifest.copy()
        prev_manifest['assemblyId'] = prev_assembly_id
        prev_manifest['billingPeriod'] = {
            'start': prev_month_start.strftime('%Y%m%dT000000.000Z'),
            'end': prev_month_end.strftime('%Y%m%dT000000.000Z')
        }
        prev_manifest['reportKeys'] = [prev_csv_key]

        prev_manifest_key = f'{prefix_path}{self.report_name}/{prev_period}/{self.report_name}-Manifest.json'
        try:
            self.s3.put_object(
                Bucket=self.bucket,
                Key=prev_manifest_key,
                Body=json.dumps(prev_manifest, indent=2).encode('utf-8')
            )
            print(f"  ✓ Copied Manifest to: {prev_manifest_key}")
        except Exception as e:
            print(f"  ⚠️  Failed to copy manifest to previous month: {e}")

        # Verify upload
        response = self.s3.list_objects_v2(
            Bucket=self.bucket,
            Prefix=f'{prefix_path}{self.report_name}/'
        )
        total_objects = response.get('KeyCount', 0)

        print(f"\n✅ Upload Complete:")
        print(f"   - CSV: {csv_key}")
        print(f"   - Manifest: {manifest_key}")
        print(f"   - Previous month CSV: {prev_csv_key}")
        print(f"   - Previous month Manifest: {prev_manifest_key}")
        print(f"   - Total objects in S3: {total_objects}")

        return {
            'passed': True,
            'success': True,
            'mode': 'direct-upload',
            'files_uploaded': 4,  # 2 for current month + 2 for previous month
            'total_objects': total_objects,
            'period': period,
            'csv_key': csv_key,
            'manifest_key': manifest_key,
            'prev_period': prev_period,
            'prev_csv_key': prev_csv_key,
            'prev_manifest_key': prev_manifest_key
        }

