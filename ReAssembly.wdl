version 1.0

# Copyright (c) 2018 Sequencing Analysis Support Core - Leiden University Medical Center
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import "tasks/bwa.wdl" as bwa
import "tasks/samtools.wdl" as samtools
import "tasks/spades.wdl" as spades
import "tasks/biopet/biopet.wdl" as biopet
import "tasks/seqtk.wdl" as seqtk
import "tasks/picard.wdl" as picard
import "tasks/common.wdl" as common

# This workflow takes an existing assembly and reads that have already passed QC.
# It maps the reads back to the assembly and uses the mapped reads to create a new assembly.
# This workflow can be run on its own spades.contigs or spades.scaffolds output
workflow ReAssembly {
    input {
        File inputAssembly
        FastqPair reads
        Int? subsampleNumber
        Int? subsampleSeed
        String outputDir
    }

    String outDir = outputDir

    # First index the assembly
    call bwa.Index as bwaIndex {
        input:
            fasta = inputAssembly,
            outputDir = outDir + "/bwaIndex"
    }

    # Map the reads back to the assembly.
    call bwa.Mem as bwaMem {
        input:
            inputFastq = reads,
            bwaIndex = bwaIndex.outputIndex,
            outputPath = outDir + "/ReadsMappedToInputAssembly.bam"
    }

    # Get the reads that mapped to the assembly. This means filtering out the UNMAP flag.
    # QCFAIL is also filtered out. For paired reads, the PROPER_PAIR flag is used.
    call samtools.View as selectMappedReads {
        input:
            inFile = bwaMem.bamFile.file,
            outputBam = true,
            excludeSpecificFilter = 12, # UNMAP,MUNMAP should both be present for the read to be filtered out.
            outputFileName = outDir + "/unmapppedReadsFiltered.bam"
    }

    call samtools.Index as mappedReadsIndex {
      input:
        bamFile = selectMappedReads.outputFile,
        bamIndexPath = sub(selectMappedReads.outputFile, ".bam$", ".bai")
    }

    call picard.SamToFastq as SamToFastq {
        input:
            inputBam = mappedReadsIndex.outputBam,
            outputRead1 = outDir + "/filtered_reads1.fq.gz",
            outputRead2 = if defined(reads.R2) then outDir + "/filtered_reads2.fq.gz" else reads.R2
    }

    # Allow subsampling in case number of mapped reads is too much for the assembler to handle.
    if (defined(subsampleNumber)) {
        call seqtk.Sample as subsampleReads1 {
            input:
                sequenceFile = SamToFastq.read1,
                fractionOrNumber = select_first([subsampleNumber]),
                seed = subsampleSeed,
                outFilePath = outDir + "/subsampling/subsampledReads1.fq.gz"
        }
        if (defined(reads.R2)) {
            call seqtk.Sample as subsampleReads2 {
                input:
                    sequenceFile = select_first([SamToFastq.read2]),
                    fractionOrNumber = select_first([subsampleNumber]),
                    seed = subsampleSeed,
                    outFilePath = outputDir + "/subsampling/subsampledReads2.fq.gz"
            }
        }
    }

    # Make sure subsampledReads are used if subsampling was used. Default to selectedReads
    File subsampledReads1 = select_first([subsampleReads1.subsampledReads, SamToFastq.read1])
    File? subsampledReads2 = if defined(subsampleNumber) then subsampleReads2.subsampledReads else SamToFastq.read2

    call spades.Spades {
        input:
            read1 = subsampledReads1,
            read2 = subsampledReads2,
            outputDir = outDir + "/spades"
    }

    output {
        File scaffolds = Spades.scaffolds
        File contigs = Spades.contigs
    }
}
