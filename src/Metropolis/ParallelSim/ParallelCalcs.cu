/*
	Contains the methods required to calculate energies in parallel.

	Created: February 21, 2014
	
	-> February 26, by Albert Wallace
	-> March 28, by Joshua Mosby
	-> April 21, by Nathan Coleman
*/

#include "ParallelCalcs.h"
#include "ParallelCalcs.cuh"
#include "ParallelBox.cuh"
#include <string>
#include "Metropolis/Utilities/FileUtilities.h"
#include "Metropolis/Box.h"
#include "Metropolis/SimulationArgs.h"
#include <thrust/reduce.h>
#include <thrust/count.h>
#include <thrust/remove.h>
#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>

#define NO -1

#define MAX_WARP 32
#define MOL_BLOCK 256
#define BATCH_BLOCK 512
#define AGG_BLOCK 512
#define THREADS_PER_BLOCK 192

using namespace std;

Box* ParallelCalcs::createBox(string inputPath, InputFileType inputType, long* startStep, long* steps)
{
	ParallelBox* box = new ParallelBox();
	if (!loadBoxData(inputPath, inputType, box, startStep, steps))
	{
		if (inputType != InputFile::Unknown)
		{
			std::cerr << "Error: Could not build from file: " << inputPath << std::endl;
			return NULL;
		}
		else
		{
			std::cerr << "Error: Can not build environment with unknown file: " << inputPath << std::endl;
			return NULL;
		}
	}
	box->copyDataToDevice();
	return (Box*) box;
}

Real ParallelCalcs::calcIntramolEnergy_NLC(Environment *enviro, MoleculeData *molecules, AtomData *atoms)
{
    //setup storage
    Real totalEnergy = 0.0;
    Real *energySum_device;
    // Molecule to be computed. Currently code only handles single solvent type systems.
    // will need to update to handle more than one solvent type (i.e., co-solvents)
    int mol1_i = 0;

    //determine number of energy calculations
    /*int N =(int) ( pow( (float) molecules->numOfAtoms[mol1_i],2)-molecules->numOfAtoms[mol1_i])/2;	 
    size_t energySumSize = N * sizeof(Real);
	Real* energySum = (Real*) malloc(energySumSize);*/

    //calculate all energies
    Real lj_energy, charge_energy, fValue, nonbonded_energy;
    int atom1, atom2;
	
    for (int atomIn1_i = 0; atomIn1_i < molecules->numOfAtoms[mol1_i]; atomIn1_i++)
    {	
	atom1 = molecules->atomsIdx[mol1_i] + atomIn1_i;
					
	for (int atomIn2_i = atomIn1_i; atomIn2_i < molecules->numOfAtoms[mol1_i]; atomIn2_i++)
	{
		atom2 = molecules->atomsIdx[mol1_i] + atomIn2_i;
			
		if (atoms->sigma[atom1] < 0 || atoms->epsilon[atom1] < 0 || atoms->sigma[atom2] < 0 || atoms->epsilon[atom2] < 0)
		{
		    continue;
		}
					  
		//calculate squared distance between atoms 
			
		Real r2 = calcAtomDist(atoms, atom1, atom2, enviro);
									  
		if (r2 == 0.0)
		{
		    continue;
		}
					
		//calculate LJ energies
		lj_energy = calc_lj(atoms, atom1, atom2, r2);

					
		//calculate Coulombic energies
		charge_energy = calcCharge(atoms->charge[atom1], atoms->charge[atom2], sqrt(r2));
						
		//gets the fValue in the same molecule
		fValue = 0.0;
				
		int hops = 0;
		for (int k = 0; k < molecules->numOfHops[mol1_i]; k++)
		{
			int hopIdx = molecules->hopsIdx[mol1_i];
			Hop currentHop = molecules->hops[hopIdx + k];
			if (currentHop.atom1 == atomIn1_i && currentHop.atom2 == atomIn2_i)
			{
				hops = currentHop.hop;
			}
		}
			
		if (hops == 3)
			fValue = 0.5;
		else if (hops > 3)
			fValue = 1.0;
			
						
		Real subtotal = (lj_energy + charge_energy) * fValue;
		totalEnergy += subtotal;

	    } /* EndFor atomIn2_i */
	} /* EndFor atomIn1_i */
	
	// Multiply single solvent molecule energy by number of solvent molecules in the system
	totalEnergy *= enviro->numOfMolecules;
	
    //free(energySum);
    return totalEnergy;
}

Real ParallelCalcs::calcSystemEnergy(Box *box)
{
        Real totalEnergy = 0;
        
        //for each molecule
        for (int mol = 0; mol < box->moleculeCount; mol++)
        {
                //use startIdx parameter to prevent double-calculating energies (Ex mols 3->5 and mols 5->3)
                totalEnergy += calcMolecularEnergyContribution(box, mol, mol + 1);
        }

    return totalEnergy;
}

Real ParallelCalcs::calcSystemEnergy_NLC(Box *box){ 

	Molecule *molecules = box->getMolecules();
	Environment *enviro = box->getEnvironment();
	int numCells[3];            	/* Number of cells in the x|y|z direction */
	Real lengthCell[3];         	/* Length of a cell in the x|y|z direction */
	int head[NCLMAX];    			/* Headers for the linked cell lists */
	int linkedCellList[NMAX];       /* Linked cell lists */
	int vectorCells[3];			  	/* Vector cells */
	int neighborCells[3];			/* Neighbor cells */

	Real rshift[3];	  		/* Shift coordinates for periodicity */
	const Real Region[3] = {enviro->x, enviro->y, enviro->z};  /* MD box lengths */
	int c1;				  	/* Used for scalar cell index */
	Real rrCut = enviro->cutoff * enviro->cutoff;	/* Cutoff squared */
	Real fValue = 1.0;				/* Holds 1,4-fudge factor value */
	Real lj_energy = 0.0;			/* Holds current Lennard-Jones energy */
	Real charge_energy = 0.0;		/* Holds current coulombic charge energy */
	Real totalEnergy = 0.0;		

	int pair_i[10000];
	int pair_j[10000];
	int iterater_i = 0;
	int iterater_j = 0;

	// Compute the # of cells for linked cell lists
	for (int k = 0; k < 3; k++)
	{
		numCells[k] = Region[k] / enviro->cutoff; 
		lengthCell[k] = Region[k] / numCells[k];
	}

	/* Make a linked-cell list --------------------------------------------*/
	int numCellsYZ = numCells[1] * numCells[2];
	int numCellsXYZ = numCells[0] * numCellsYZ;

	// Reset the headers, head
	for (int c = 0; c < numCellsXYZ; c++)
	{
		head[c] = EMPTY;
	}

	// Scan cutoff index atom in each molecule to construct headers, head, & linked lists, lscl
	for (int i = 0; i < enviro->numOfMolecules; i++)
	{
		std::vector<int> molPrimaryIndexArray = (*(*(enviro->primaryAtomIndexArray))[molecules[i].type]);
		int primaryIndex = molPrimaryIndexArray[0]; // Use first primary index to determine cell placement

		vectorCells[0] = molecules[i].atoms[primaryIndex].x / lengthCell[0]; 
		vectorCells[1] = molecules[i].atoms[primaryIndex].y / lengthCell[1];
		vectorCells[2] = molecules[i].atoms[primaryIndex].z / lengthCell[2];

		// Translate the vector cell index to a scalar cell index
		int c = vectorCells[0]*numCellsYZ + vectorCells[1]*numCells[2] + vectorCells[2];

		// Link to the previous occupant (or EMPTY if you're the 1st)
		linkedCellList[i] = head[c];

		// The last one goes to the header
		head[c] = i;
	} /* Endfor molecule i */


	for (vectorCells[0] = 0; vectorCells[0] < numCells[0]; (vectorCells[0])++)
	{
		for (vectorCells[1] = 0; vectorCells[1] < numCells[1]; (vectorCells[1])++)
		{
			for (vectorCells[2] = 0; vectorCells[2] < numCells[2]; (vectorCells[2])++)
			{

				// Calculate a scalar cell index
				int c = vectorCells[0]*numCellsYZ + vectorCells[1]*numCells[2] + vectorCells[2];
				// Skip this cell if empty
				if (head[c] == EMPTY) continue;

				// Scan the neighbor cells (including itself) of cell c
				for (neighborCells[0] = vectorCells[0]-1; neighborCells[0] <= vectorCells[0]+1; (neighborCells[0])++)
					for (neighborCells[1] = vectorCells[1]-1; neighborCells[1] <= vectorCells[1]+1; (neighborCells[1])++)
						for (neighborCells[2] = vectorCells[2]-1; neighborCells[2] <= vectorCells[2]+1; (neighborCells[2])++)
						{
							// Periodic boundary condition by shifting coordinates
							for (int a = 0; a < 3; a++)
							{
								if (neighborCells[a] < 0)
								{
									rshift[a] = -Region[a];
								}
								else if (neighborCells[a] >= numCells[a])
								{
									rshift[a] = Region[a];
								}
								else
								{
									rshift[a] = 0.0;
								}
							}
							// Calculate the scalar cell index of the neighbor cell
							c1 = ((neighborCells[0] + numCells[0]) % numCells[0]) * numCellsYZ
									+((neighborCells[1] + numCells[1]) % numCells[1]) * numCells[2]
									                                                             +((neighborCells[2] + numCells[2]) % numCells[2]);
							// Skip this neighbor cell if empty
							if (head[c1] == EMPTY)
							{
								continue;
							}

							// Scan atom i in cell c
							int i = head[c];
							while (i != EMPTY)
							{

								// Scan atom j in cell c1
								int j = head[c1];
								while (j != EMPTY)
								{
									bool included = false;

									// Avoid double counting of pairs
									if (i < j)
									{	
										std::vector<int> currentMolPrimaryIndexArray = (*(*(enviro->primaryAtomIndexArray))[molecules[i].type]);
										std::vector<int> otherMolPrimaryIndexArray;
										if (molecules[i].type == molecules[j].type)
										{
											otherMolPrimaryIndexArray = currentMolPrimaryIndexArray;
										}
										else 
										{
											otherMolPrimaryIndexArray = (*(*(enviro->primaryAtomIndexArray))[molecules[j].type]);
										}

										for (int i1 = 0; i1 < currentMolPrimaryIndexArray.size(); i1++)
										{
											for (int i2 = 0; i2 < otherMolPrimaryIndexArray.size(); i2++)
											{
												int primaryIndex1 = currentMolPrimaryIndexArray[i1];
												int primaryIndex2 = otherMolPrimaryIndexArray[i2];
												Atom atom1 = molecules[i].atoms[primaryIndex1];
												Atom atom2 = molecules[j].atoms[primaryIndex2];

												Real dr[3];		  /* Pair vector dr = atom[i]-atom[j] */
												dr[0] = atom1.x - (atom2.x + rshift[0]);
												dr[1] = atom1.y - (atom2.y + rshift[1]);
												dr[2] = atom1.z - (atom2.z + rshift[2]);
												Real rr = (dr[0] * dr[0]) + (dr[1] * dr[1]) + (dr[2] * dr[2]);			

												// Calculate energy for entire molecule interaction if rij < Cutoff for atom index
												if (rr < rrCut)
												{	
													//totalEnergy += calcInterMolecularEnergy(molecules, i, j, enviro, subLJ, subCharge) * fValue;
													pair_i[iterater_i] = i;
													iterater_i++;
													pair_j[iterater_j] = j;
													iterater_j++;
													included = true;
													break;
												} /* Endif rr < rrCut */

											}
											if (included)
											{
												break;
											}
										}
									} /* Endif i<j */

									j = linkedCellList[j];
								} /* Endwhile j not empty */

								i = linkedCellList[i];
							} /* Endwhile i not empty */
						} /* Endfor neighbor cells, c1 */
			} /* Endfor central cell, c */
		}
	}


	int *d_pair_i;
	int *d_pair_j;
	cudaMalloc((void **)&d_pair_i, sizeof(int)*10000);
	cudaMalloc((void **)&d_pair_j, sizeof(int)*10000);

	cudaMemcpy(d_pair_i, pair_i, sizeof(int)*10000, cudaMemcpyHostToDevice);
	cudaMemcpy(d_pair_j, pair_j, sizeof(int)*10000, cudaMemcpyHostToDevice);

	thrust::device_vector<Real> part_energy(10000, 0);//this will store the result
	ParallelBox *pBox = (ParallelBox*) box;

	if (pBox == NULL)
	{
		return 0;
	}
	MoleculeData *d_molecules = pBox->moleculesD;
	AtomData *d_atoms = pBox->atomsD;
	Environment *d_enviro = pBox->environmentD;
	Real *raw_ptr = thrust::raw_pointer_cast(&part_energy[0]);
	int blocksPerGrid = 53;
	calcEnergy_NLC<<<blocksPerGrid, THREADS_PER_BLOCK>>>(d_pair_i, d_pair_j, raw_ptr, d_molecules, d_atoms, d_enviro, iterater_i);

	Real total_energy = thrust::reduce(part_energy.begin(), part_energy.end());

	cudaFree(d_pair_i);
	cudaFree(d_pair_j);

	return total_energy;// + calcIntramolEnergy_NLC(enviro, pBox->moleculesD, pBox->atomsD);
}

__global__ void ParallelCalcs::calcEnergy_NLC(int* d_pair_i, int* d_pair_j, Real *part_energy, MoleculeData *molecules, AtomData *atoms, Environment *enviro, int limit)
{

	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if(i < limit){
		part_energy[i] = part_energy[i] + calcInterMolecularEnergy(molecules, atoms, d_pair_i[i], d_pair_j[i], enviro) * 1.0;
	}
}
	


/*__device__ Real ParallelCalcs::calcEnergyContribution(MoleculeData *molecules, AtomData *atoms, Environment *enviro, int currentMol, int startIdx, )
{
    int otherMol = blockIdx.x * blockDim.x + threadIdx.x;

    //checks validity of molecule pair
    if (otherMol < molecules->moleculeCount && otherMol >= startIdx && otherMol != currentMol)
    {
        bool included = false;
        for (int i = 0; i < molecules->totalPrimaryIndexSize; i++)
        {
            int currentMoleculeIndexCount = molecules->primaryIndexes[i];
            int currentTypeIndex = i+1;
            int potentialCurrentMoleculeType = molecules->primaryIndexes[currentTypeIndex];

            if (potentialCurrentMoleculeType == molecules->type[currentMol])
            {
                int *currentMolPrimaryIndexArray = molecules->primaryIndexes + currentTypeIndex + 1;
		int currentMolPrimaryIndexArrayLength = currentMoleculeIndexCount - 1;

                for (int k = 0; k < molecules->totalPrimaryIndexSize; k++)
                {
                    int otherMoleculeIndexCount = molecules->primaryIndexes[k];
                    int otherTypeIndex = k+1;
                    int potentialOtherMoleculeType = molecules->primaryIndexes[otherTypeIndex];

                    if (potentialOtherMoleculeType == molecules->type[otherMol])
                    {
                        int *otherMolPrimaryIndexArray = molecules->primaryIndexes + otherTypeIndex + 1;
                        int otherMolPrimaryIndexArrayLength = otherMoleculeIndexCount - 1;

                        for (int m = 0; m < currentMolPrimaryIndexArrayLength; m++)
                        {
                            for (int n = 0; n < otherMolPrimaryIndexArrayLength; n++)
                            {
                                //find primary atom indices for this pair of molecules
				int atom1 = molecules->atomsIdx[currentMol] + *(currentMolPrimaryIndexArray + m);
				int atom2 = molecules->atomsIdx[otherMol] + *(otherMolPrimaryIndexArray + n);
	
				dr[0] = atoms->x[atom1] - (atoms->x[atom2] + rshift[0]);
                                dr[1] = atoms->y[atom1] - (atoms->y[atom2] + rshift[1]);
                                dr[2] = atoms->z[atom1] - (atoms->z[atom2] + rshift[2]);
                                const Real rr = (dr[0] * dr[0]) + (dr[1] * dr[1]) + (dr[2] * dr[2]);

                                // Calculate energy for entire molecule interaction if rij < Cutoff for atom index

                                if (rr < rrCut) {
                                    included = true;
                                    part_energy[index] = part_energy[index] + calcInterMolecularEnergy(molecules, atoms, i, j, enviro) * fValue;
                                    break;
                                 }
                            }
                            if (included)
                                break;
                        }
		     }
                     if (included)
                         break;
                     else
                         k += otherMoleculeIndexCount;
                }
            }   
            if (included)
                break;
            else
                i += currentMoleculeIndexCount;
        }
    }

}*/

	__device__ Real ParallelCalcs::calcInterMolecularEnergy(MoleculeData *molecules, AtomData *atoms, int mol1, int mol2, Environment *enviro)
	{
		Real totalEnergy = 0;
		for (int i = 0; i < molecules->numOfAtoms[mol1]; i++)
		{
			for (int j = 0; j < molecules->numOfAtoms[mol2]; j++)
			{
				int atom1 = molecules->atomsIdx[mol1] + i;
				int atom2 = molecules->atomsIdx[mol2] + j;
				if (atoms->sigma[atom1] >= 0 && atoms->epsilon[atom1] >= 0 && atoms->sigma[atom2] >= 0 && atoms->epsilon[atom2] >= 0)
				{
					//calculate squared distance between atoms 
					Real r2 = calcAtomDist(atoms, atom1, atom2, enviro);
					totalEnergy += calc_lj(atoms, atom1, atom2, r2);
					totalEnergy += calcCharge(atoms->charge[atom1], atoms->charge[atom2], sqrt(r2));
				}
			}

		}
		return totalEnergy;
	}


Real ParallelCalcs::calcMolecularEnergyContribution(Box *box, int molIdx, int startIdx)
{
	ParallelBox *pBox = (ParallelBox*) box;
	
	if (pBox == NULL)
	{
		return 0;
	}
	
	return calcBatchEnergy(pBox, createMolBatch(pBox, molIdx, startIdx), molIdx);
}

struct isThisTrue {
	__device__ bool operator()(const int &x) {
	  return x != NO;
	}
};

int ParallelCalcs::createMolBatch(ParallelBox *box, int currentMol, int startIdx)
{
	//initialize neighbor molecule slots to NO
	cudaMemset(box->nbrMolsD, NO, box->moleculeCount * sizeof(int));
	
	//check molecule distances in parallel, conditionally replacing NO with index value in box->nbrMolsD
	checkMoleculeDistances<<<box->moleculeCount / MOL_BLOCK + 1, MOL_BLOCK>>>(box->moleculesD, box->atomsD, currentMol, startIdx, box->environmentD, box->nbrMolsD);
	
	thrust::device_ptr<int> neighborMoleculesOnDevice = thrust::device_pointer_cast(&box->nbrMolsD[0]);
	thrust::device_ptr<int> moleculesInBatchOnDevice = thrust::device_pointer_cast(&box->molBatchD[0]);
	
	//copy over neighbor molecules that don't have NO as their index value
	thrust::device_ptr<int> lastElementFound = thrust::copy_if(neighborMoleculesOnDevice, neighborMoleculesOnDevice + box->moleculeCount, moleculesInBatchOnDevice, isThisTrue());
	
	return lastElementFound - moleculesInBatchOnDevice;
}

Real ParallelCalcs::calcBatchEnergy(ParallelBox *box, int numMols, int molIdx)
{
	if (numMols <= 0) return 0;
	
	//There will only be as many energy segments filled in as there are molecules in the batch.
	int validEnergies = numMols * box->maxMolSize * box->maxMolSize;
	
	//calculate interatomic energies between changed molecule and all molecules in batch
	calcInterMolecularEnergy<<<validEnergies / BATCH_BLOCK + 1, BATCH_BLOCK>>>
	(box->moleculesD, box->atomsD, molIdx, box->environmentD, box->energiesD, validEnergies, box->molBatchD, box->maxMolSize);
	
	//Using Thrust here for a sum reduction on all of the individual energy contributions in box->energiesD.
	thrust::device_ptr<Real> energiesOnDevice = thrust::device_pointer_cast(&box->energiesD[0]);
	return thrust::reduce(energiesOnDevice, energiesOnDevice + validEnergies, (Real) 0, thrust::plus<Real>());
}

__global__ void ParallelCalcs::checkMoleculeDistances(MoleculeData *molecules, AtomData *atoms, int currentMol, int startIdx, Environment *enviro, int *inCutoff)
{
	int otherMol = blockIdx.x * blockDim.x + threadIdx.x;
	
	//checks validity of molecule pair
	if (otherMol < molecules->moleculeCount && otherMol >= startIdx && otherMol != currentMol)
	{
		bool included = false;    	
		for (int i = 0; i < molecules->totalPrimaryIndexSize; i++)
		{
		    int currentMoleculeIndexCount = molecules->primaryIndexes[i];
		    int currentTypeIndex = i+1;
		    int potentialCurrentMoleculeType = molecules->primaryIndexes[currentTypeIndex];
			
		    if (potentialCurrentMoleculeType == molecules->type[currentMol])
		    {
	    	        int *currentMolPrimaryIndexArray = molecules->primaryIndexes + currentTypeIndex + 1;
		        int currentMolPrimaryIndexArrayLength = currentMoleculeIndexCount - 1;		

			for (int k = 0; k < molecules->totalPrimaryIndexSize; k++)
			{
		    	    int otherMoleculeIndexCount = molecules->primaryIndexes[k];
    			    int otherTypeIndex = k+1;
			    int potentialOtherMoleculeType = molecules->primaryIndexes[otherTypeIndex];
			
			    if (potentialOtherMoleculeType == molecules->type[otherMol])
			    {
				int *otherMolPrimaryIndexArray = molecules->primaryIndexes + otherTypeIndex + 1;
				int otherMolPrimaryIndexArrayLength = otherMoleculeIndexCount - 1;
					
				for (int m = 0; m < currentMolPrimaryIndexArrayLength; m++)
				{
				    for (int n = 0; n < otherMolPrimaryIndexArrayLength; n++)
				    {
					//find primary atom indices for this pair of molecules
					int atom1 = molecules->atomsIdx[currentMol] + *(currentMolPrimaryIndexArray + m);
					int atom2 = molecules->atomsIdx[otherMol] + *(otherMolPrimaryIndexArray + n);
			
					//calculate periodic difference in coordinates
					Real deltaX = makePeriodic(atoms->x[atom1] - atoms->x[atom2], enviro->x);
					Real deltaY = makePeriodic(atoms->y[atom1] - atoms->y[atom2], enviro->y);
					Real deltaZ = makePeriodic(atoms->z[atom1] - atoms->z[atom2], enviro->z);
		
					Real r2 = (deltaX * deltaX) +
							    (deltaY * deltaY) + 
							    (deltaZ * deltaZ);
		
					//if within curoff, write index to inCutoff
					if (r2 < enviro->cutoff * enviro->cutoff)
					{
					    inCutoff[otherMol] = otherMol;
					    included = true;
					    break;
					}	
				    }
				    if (included)
					break;
				}
			    }
			    if (included)
				break;
			    else
			    	k += otherMoleculeIndexCount;
			 }
		    }
		    if (included)
			break;
		    else
			i += currentMoleculeIndexCount;
		}
	
		/*//find primary atom indices for this pair of molecules
		for (int i = 0; i < molecules->totalPrimaryIndexSize; i++)
		{
		    printf("checkMoleculeDistances:totalPrimaryIndexSize: %d Array: ",molecules->totalPrimaryIndexSize);
		    printf("%d: ", i);
		    printf("%d", molecules->primaryIndexes[i]);
		} 
		printf("\n");
		//int atom1 = molecules->atomsIdx[currentMol] + enviro->primaryAtomIndex;
		//int atom2 = molecules->atomsIdx[otherMol] + enviro->primaryAtomIndex;


		int atom1 = molecules->atomsIdx[currentMol] + enviro->primaryAtomIndex;
		int atom2 = molecules->atomsIdx[otherMol] + enviro->primaryAtomIndex;
			
		//calculate periodic difference in coordinates
		Real deltaX = makePeriodic(atoms->x[atom1] - atoms->x[atom2], enviro->x);
		Real deltaY = makePeriodic(atoms->y[atom1] - atoms->y[atom2], enviro->y);
		Real deltaZ = makePeriodic(atoms->z[atom1] - atoms->z[atom2], enviro->z);
		
		Real r2 = (deltaX * deltaX) +
					(deltaY * deltaY) + 
					(deltaZ * deltaZ);
		
		//if within curoff, write index to inCutoff
		if (r2 < enviro->cutoff * enviro->cutoff)
		{
			inCutoff[otherMol] = otherMol;
		}*/
	}
}

__global__ void ParallelCalcs::calcInterMolecularEnergy(MoleculeData *molecules, AtomData *atoms, int currentMol, Environment *enviro, Real *energies, int energyCount, int *molBatch, int maxMolSize)
{
	int energyIdx = blockIdx.x * blockDim.x + threadIdx.x;
	int segmentSize = maxMolSize * maxMolSize;
	
	//check validity of thread
	if (energyIdx < energyCount and molBatch[energyIdx / segmentSize] != NO)
	{
		//get other molecule index
		int otherMol = molBatch[energyIdx / segmentSize];
		
		//get atom pair for this thread
		int x = (energyIdx % segmentSize) / maxMolSize;
		int y = (energyIdx % segmentSize) % maxMolSize;
		
		//check validity of atom pair
		if (x < molecules->numOfAtoms[currentMol] && y < molecules->numOfAtoms[otherMol])
		{
			//get atom indices
			int atom1 = molecules->atomsIdx[currentMol] + x;
			int atom2 = molecules->atomsIdx[otherMol] + y;
			
			//check validity of atoms (ensure they are not dummy atoms)
			if (atoms->sigma[atom1] >= 0 && atoms->epsilon[atom1] >= 0 && atoms->sigma[atom2] >= 0 && atoms->epsilon[atom2] >= 0)
			{
				Real totalEnergy = 0;
			  
				//calculate periodic distance between atoms
				Real deltaX = makePeriodic(atoms->x[atom1] - atoms->x[atom2], enviro->x);
				Real deltaY = makePeriodic(atoms->y[atom1] - atoms->y[atom2], enviro->y);
				Real deltaZ = makePeriodic(atoms->z[atom1] - atoms->z[atom2], enviro->z);
				
				Real r2 = (deltaX * deltaX) +
					 (deltaY * deltaY) + 
					 (deltaZ * deltaZ);
				
				//calculate interatomic energies
				totalEnergy += calc_lj(atoms, atom1, atom2, r2);
				totalEnergy += calcCharge(atoms->charge[atom1], atoms->charge[atom2], sqrt(r2));
				
				//store energy
				energies[energyIdx] = totalEnergy;
			}
		}
	}
}

__host__ __device__ Real ParallelCalcs::calc_lj(AtomData *atoms, int atom1, int atom2, Real r2)
{
    //store LJ constants locally
    Real sigma = calcBlending(atoms->sigma[atom1], atoms->sigma[atom2]);
    Real epsilon = calcBlending(atoms->epsilon[atom1], atoms->epsilon[atom2]);
    
    if (r2 == 0.0)
    {
        return 0.0;
    }
    else
    {
    	//calculate terms
    	const Real sig2OverR2 = (sigma*sigma) / r2;
		const Real sig6OverR6 = (sig2OverR2*sig2OverR2*sig2OverR2);
    	const Real sig12OverR12 = (sig6OverR6*sig6OverR6);
    	const Real energy = 4.0 * epsilon * (sig12OverR12 - sig6OverR6);
        return energy;
    }
}

__device__ Real ParallelCalcs::calcAtomDist(AtomData *atoms, int atomIdx1, int atomIdx2, Environment *enviro)
{
	//calculate difference in coordinates
	Real deltaX = makePeriodic(atoms->x[atomIdx1] - atoms->x[atomIdx2], enviro->x);
	Real deltaY = makePeriodic(atoms->y[atomIdx1] - atoms->y[atomIdx2], enviro->y);
	Real deltaZ = makePeriodic(atoms->z[atomIdx1] - atoms->z[atomIdx2], enviro->z);
				
	//calculate squared distance (r2 value) and return
	return (deltaX * deltaX) + (deltaY * deltaY) + (deltaZ * deltaZ);
}
__device__ __host__ Real ParallelCalcs::calcCharge(Real charge1, Real charge2, Real r)
{  
    if (r == 0.0)
    {
        return 0.0;
    }
    else
    {
    	// conversion factor below for units in kcal/mol
    	const Real e = 332.06;
        return (charge1 * charge2 * e) / r;
    }
}

__device__ __host__ Real ParallelCalcs::makePeriodic(Real x, Real boxDim)
{
    
    while(x < -0.5 * boxDim)
    {
        x += boxDim;
    }

    while(x > 0.5 * boxDim)
    {
        x -= boxDim;
    }

    return x;

}

__device__ __host__ Real ParallelCalcs::calcBlending(Real d1, Real d2)
{
    return sqrt(d1 * d2);
}

__device__ int ParallelCalcs::getXFromIndex(int idx)
{
    int c = -2 * idx;
    int discriminant = 1 - 4 * c;
    int qv = (-1 + sqrtf(discriminant)) / 2;
    return qv + 1;
}

__device__ int ParallelCalcs::getYFromIndex(int x, int idx)
{
    return idx - (x * x - x) / 2;
}
