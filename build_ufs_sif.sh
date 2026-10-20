#!/bin/bash
# Build the UFS HPC-ME Apptainer SIF on Ursa (or any Slurm/Apptainer HPC system).
#
# Compute nodes on Ursa have no outbound internet. Run this two-step process:
#
# Step 1 — on a LOGIN node (has internet), pull the base image:
#   bash build_ufs_sif.sh --pull-base
#
# Step 2 — submit the Spack build to a COMPUTE node:
#   cd /path/to/HPC-ME && sbatch build_ufs_sif.sh
#
#SBATCH --job-name=build-ufs-sif
#SBATCH --partition=u1-compute
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=04:00:00
#SBATCH --output=build_ufs_sif_%j.log
#SBATCH --error=build_ufs_sif_%j.log

set -euo pipefail

# -----------------------------------------------------------------------
# --pull-base mode: submit a short Slurm job to pull + convert the base
# image on a compute node (login nodes forbid CPU-intensive mksquashfs).
# Run this from a login node:
#   bash build_ufs_sif.sh --pull-base
# -----------------------------------------------------------------------
if [[ "${1:-}" == "--pull-base" ]]; then
    BUILD_DIR="${BUILD_DIR:-${SCRATCH:-/scratch4/NCEPDEV/stmp/${USER}}/ufs-container}"
    mkdir -p "${BUILD_DIR}"
    PULL_SCRIPT="${BUILD_DIR}/pull_base_image.sh"
    cat > "${PULL_SCRIPT}" << PULLEOF
#!/bin/bash
#SBATCH --job-name=pull-base-sif
#SBATCH --partition=u1-compute
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=00:30:00
#SBATCH --output=${BUILD_DIR}/pull_base_image_%j.log
#SBATCH --error=${BUILD_DIR}/pull_base_image_%j.log
set -euo pipefail
export APPTAINER_CACHEDIR="${BUILD_DIR}/.apptainer_cache"
export APPTAINER_TMPDIR="${BUILD_DIR}/.apptainer_tmp"
mkdir -p "\${APPTAINER_CACHEDIR}" "\${APPTAINER_TMPDIR}"
echo "Pulling base image..."
apptainer pull "${BUILD_DIR}/rocky9-intel2025.3-base.sif" \\
    docker://intel/oneapi-hpckit:2025.3.0-0-devel-rockylinux9
echo "Done: ${BUILD_DIR}/rocky9-intel2025.3-base.sif"
PULLEOF
    chmod +x "${PULL_SCRIPT}"
    JOB=$(sbatch --parsable "${PULL_SCRIPT}")
    echo "Submitted pull job: ${JOB}"
    echo "Monitor: squeue -j ${JOB}"
    echo "Log:     ${BUILD_DIR}/pull_base_image_${JOB}.log"
    echo ""
    echo "Once complete, submit the main build:"
    echo "  cd ${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)} && sbatch build_ufs_sif.sh"
    exit 0
fi

# -----------------------------------------------------------------------
# Configuration — edit these if needed, or override via environment:
#   DEF_FILE=/path/to/file.def sbatch build_ufs_sif.sh
#   sbatch --export=ALL,DEF_FILE=/path/to/file.def build_ufs_sif.sh
# -----------------------------------------------------------------------
# SLURM_SUBMIT_DIR is set by Slurm to the directory where sbatch was run
SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEF_FILE="${DEF_FILE:-${SUBMIT_DIR}/ufs-rockylinux9-intel2025.3.def}"
SIF_NAME="ufs-hpcme-intel2025.sif"
BUILD_DIR="${BUILD_DIR:-${SCRATCH:-/scratch4/NCEPDEV/stmp/${USER}}/ufs-container}"
# -----------------------------------------------------------------------

echo "================================================================"
echo " UFS HPC-ME SIF Builder"
echo " Started   : $(date)"
echo " Host      : $(hostname)"
echo " Build dir : ${BUILD_DIR}"
echo " Def file  : ${DEF_FILE}"
echo " Output    : ${BUILD_DIR}/${SIF_NAME}"
echo "================================================================"

# Verify .def file exists
if [[ ! -f "${DEF_FILE}" ]]; then
    echo "ERROR: Definition file not found: ${DEF_FILE}"
    exit 1
fi

# Verify base SIF exists (must be pulled on login node first)
BASE_SIF="${BUILD_DIR}/rocky9-intel2025.3-base.sif"
if [[ ! -f "${BASE_SIF}" ]]; then
    echo "ERROR: Base image SIF not found: ${BASE_SIF}"
    echo "       Run this first on a login node:"
    echo "         bash ${DEF_FILE%/*}/build_ufs_sif.sh --pull-base"
    exit 1
fi

# Create build directory
mkdir -p "${BUILD_DIR}"

# Verify apptainer is available
if ! command -v apptainer &>/dev/null; then
    echo "apptainer not found in PATH — trying to load module"
    module load apptainer 2>/dev/null || module load singularity 2>/dev/null || {
        echo "ERROR: apptainer/singularity not available"
        exit 1
    }
fi
echo "Using: $(apptainer --version)"

# Check available disk space (warn if < 60 GB)
AVAIL_KB=$(df -k "${BUILD_DIR}" | awk 'NR==2 {print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
echo "Available disk space: ${AVAIL_GB} GB"
if [[ ${AVAIL_GB} -lt 60 ]]; then
    echo "WARNING: Less than 60 GB available — build may fail"
fi

# Set Apptainer cache/tmp to scratch to avoid filling home quota
export APPTAINER_CACHEDIR="${BUILD_DIR}/.apptainer_cache"
export APPTAINER_TMPDIR="${BUILD_DIR}/.apptainer_tmp"
mkdir -p "${APPTAINER_CACHEDIR}" "${APPTAINER_TMPDIR}"

# Probe Intel MPI path in the base image and warn if version differs
echo ""
echo "--- Probing Intel MPI version in base image ---"
MPI_VERSION=$(apptainer exec docker://intel/oneapi-hpckit:2025.3.0-0-devel-rockylinux9 \
    ls /opt/intel/oneapi/mpi/ 2>/dev/null | head -1) || MPI_VERSION="unknown"
echo "Detected Intel MPI version in base image: ${MPI_VERSION}"
if [[ "${MPI_VERSION}" != "2021.13" && "${MPI_VERSION}" != "unknown" ]]; then
    echo "WARNING: .def file references intel-oneapi-mpi@2021.13 but base image has ${MPI_VERSION}"
    echo "         Update the MPI version in ${DEF_FILE} before building"
    echo "         Proceeding anyway — build may fail at spack concretize step"
fi
echo ""

# -----------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------
SIF_PATH="${BUILD_DIR}/${SIF_NAME}"

echo "Building SIF — this takes 2-3 hours..."
echo "Log: ${BUILD_DIR}/build_ufs_sif_$(date +%Y%m%d_%H%M%S).log"

apptainer build \
    --fakeroot \
    --nv \
    "${SIF_PATH}" \
    "${DEF_FILE}" \
    2>&1 | tee "${BUILD_DIR}/build_ufs_sif_$(date +%Y%m%d_%H%M%S).log"

RC=${PIPESTATUS[0]}

echo ""
echo "================================================================"
if [[ ${RC} -eq 0 ]]; then
    echo " Build SUCCEEDED: $(date)"
    echo " SIF location  : ${SIF_PATH}"
    SIF_SIZE=$(du -sh "${SIF_PATH}" | cut -f1)
    echo " SIF size      : ${SIF_SIZE}"
    echo ""
    echo " Quick verification:"
    apptainer exec "${SIF_PATH}" bash -c "
        echo '  icx   : '$(icx   --version 2>&1 | head -1)
        echo '  ifx   : '$(ifx   --version 2>&1 | head -1)
        echo '  mpirun: '$(mpirun --version 2>&1 | head -1)
        echo '  hdf5  : '$(h5dump --version 2>&1 | head -1)
        echo '  nf-config: '$(nf-config --version 2>&1)
    " 2>/dev/null || true
    echo ""
    echo " Next step — compile UFS inside the container:"
    echo "   apptainer exec \\"
    echo "     --bind /scratch4/NCEPDEV/stmp/\${USER} \\"
    echo "     --bind /path/to/ufs-weather-model:/ufs \\"
    echo "     ${SIF_PATH} \\"
    echo "     bash -c 'source /usr/lmod/lmod/init/bash && \\"
    echo "              module use /ufs/modulefiles && \\"
    echo "              module load ufs_container.hpcme-intel2025 && \\"
    echo "              cd /ufs && ./build.sh'"
else
    echo " Build FAILED (exit code ${RC}): $(date)"
    echo " Check logs in ${BUILD_DIR}/"
    exit ${RC}
fi
echo "================================================================"
