require "torch"
require "cunn"
require "cutorch"
require "image"


function rotationMatrix(angle)
	--Returns a 3D rotation matrix
	local rotMatrix = torch.Tensor{1,0,0,0,0,torch.cos(angle),-torch.sin(angle),0,0,torch.sin(angle),torch.cos(angle),0}:reshape(3,4)
	local rotMatrix = torch.Tensor{1,0,0,0,torch.cos(angle),-torch.sin(angle),0,torch.sin(angle),torch.cos(angle)}:reshape(3,3)
	return rotMatrix
end

function rotation3d(imgObject, angleMax, sliceSize, clipMin, clipMax,rotate)

	imgOriginal = imgObject:loadImg(clipMin,clipMax,sliceSize)
	
	sliceSize_2 = torch.floor(sliceSize/2)


	intervalTimer = torch.Timer()

	local xSize,ySize,zSize = sliceSize, sliceSize, sliceSize -- Making a cube hence all dimensions are the same (possibly change)
	local totSize = xSize*ySize*zSize

	--Coords
	local x,y,z = torch.linspace(1,xSize,xSize), torch.linspace(1,ySize,ySize), torch.linspace(1,zSize,zSize) -- Old not centered coords
	local zz = z:repeatTensor(ySize*xSize)
	local yy = y:repeatTensor(zSize):sort():long():repeatTensor(xSize):double()
	local xx = x:repeatTensor(zSize*ySize):sort():long():double()
	--ones = torch.ones(totSize)

	--coords = torch.cat({xx:reshape(totSize,1),yy:reshape(totSize,1),zz:reshape(totSize,1),ones:reshape(totSize,1)},2)
	coords = torch.cat({xx:reshape(totSize,1),yy:reshape(totSize,1),zz:reshape(totSize,1)},2)
	coords = coords:cuda()

	-- Translate coords to be about the origin i.e. mean subtract
	--local translate = torch.ones(totSize,3):fill(-sliceSize/2)
	local translate = torch.ones(totSize,3):fill(-sliceSize/2):cuda()
	local coordsT = coords + translate

	-- Rotated coords
	-- Rotation matrix
	local angle = torch.uniform(-angleMax,angleMax)
	local rotMatrix = rotationMatrix(angle)
	rotMatrix = rotationMatrix(angle):cuda()

	-- Rotation
	local newCoords = coordsT*rotMatrix:transpose(1,2)

	--SPacing
	--local spacing  = torch.diag(torch.Tensor{1/imgObject.zSpacing, 1/imgObject.ySpacing, 1/imgObject.xSpacing})
	local spacing  = torch.diag(torch.Tensor{1/imgObject.zSpacing, 1/imgObject.ySpacing, 1/imgObject.xSpacing}):cuda()

	newCoords = newCoords*spacing -- Using spacing information to transform back to the "real world"

	-- Translate coords back to original coordinate system where the centre is on the nodule
	local noduleZ, noduleY, noduleX  = imgObject.z, imgObject.y, imgObject.x
	local noduleTranslate = torch.ones(totSize,3)
	noduleTranslate = torch.ones(totSize,3):cuda()
	noduleTranslate[{{},{1}}]:fill(noduleZ)
	noduleTranslate[{{},{2}}]:fill(noduleY)
	noduleTranslate[{{},{3}}]:fill(noduleX)

	local newCoordsT = newCoords + noduleTranslate -- These coords are now in the original space
	local newCoords1 = newCoordsT:clone()
	--minMax = torch.min(torch.Tensor{xSize,ySize,zSize})

	-- Need all 8 corners of the cube in which newCoords[i,j,k] lies
	-- ozo means onesZerosOnes
	local zzz = torch.zeros(totSize,3)
	zzz = torch.zeros(totSize,3):cuda()
	local ooo = torch.ones(totSize,3)
	ooo = torch.ones(totSize,3):cuda()

	local function fillzo(zzz_ooo,z_o,column)
		zzz_ooo_clone = zzz_ooo:clone()
		zzz_ooo_clone:select(2,column):fill(z_o)
		--return zzz_ooo_clone
		return zzz_ooo_clone:cuda()
	end

	ozz = fillzo(zzz,1,1)
	zoz = fillzo(zzz,1,2)
	zzo = fillzo(zzz,1,3)
	zoo = fillzo(ooo,0,1)
	ozo = fillzo(ooo,0,2)
	ooz = fillzo(ooo,0,3)

	xyz = newCoords1:clone()
	xyz:floor()
	--print(xyz)

	ijk = newCoords1 - xyz

	xyz[xyz:lt(1)] = 1
	xyz[{{},{1}}][xyz[{{},{1}}]:gt(imgOriginal:size()[1]-1)] = imgOriginal:size()[1]-1
	xyz[{{},{2}}][xyz[{{},{2}}]:gt(imgOriginal:size()[2]-1)] = imgOriginal:size()[2]-1
	xyz[{{},{3}}][xyz[{{},{3}}]:gt(imgOriginal:size()[3]-1)] = imgOriginal:size()[3]-1
	--print(xyz)

	x1y1z1 = xyz + ooo
	x1yz = xyz + ozz
	xy1z = xyz + zoz
	xyz1 = xyz + zzo
	x1y1z = xyz + ooz
	x1yz1 = xyz + ozo
	xy1z1 = xyz + zoo

	-- Subtract the new coordinates from the 8 corners to get our distances ijk which are our weights
	ijk = ijk:cuda()
	ooo = ooo:cuda()
	--
	i,j,k = ijk[{{},{1}}], ijk[{{},{2}}], ijk[{{},{3}}]
	i1j1k1 = ooo - ijk -- (1-i)(1-j)(1-k)
	i1,j1,k1 = i1j1k1[{{},{1}}], i1j1k1[{{},{2}}], i1j1k1[{{},{3}}] 

	-- Functions to return f(x,y,z) given xyz
	function flattenIndices(sp_indices, shape)
		sp_indices = sp_indices - 1
		n_elem, n_dim = sp_indices:size(1), sp_indices:size(2)
		flat_ind = torch.LongTensor(n_elem):fill(1)

		mult = 1
		for d = n_dim, 1, -1 do
			flat_ind:add(sp_indices[{{}, d}] * mult)
			mult = mult * shape[d]
		end
		return flat_ind
	end

	function getElements(tensor, sp_indices)
		sp_indices = sp_indices:long()
		flat_indices = flattenIndices(sp_indices, tensor:size()) 
		flat_tensor = tensor:view(-1):double()
		--flat_tensor = tensor:view(-1)
		return flat_tensor:index(1, flat_indices)
	end


	--[[
	fxyz = getElements(imgOriginal,xyz)
	fx1yz = getElements(imgOriginal,x1yz)
	fxy1z = getElements(imgOriginal,xy1z)
	fxyz1 = getElements(imgOriginal,xyz1)
	fx1y1z = getElements(imgOriginal,x1y1z)
	fx1yz1 = getElements(imgOriginal,x1yz1)
	fxy1z1 = getElements(imgOriginal,xy1z1)
	fx1y1z1 = getElements(imgOriginal,x1y1z1)
	]]--


	fxyz = getElements(imgOriginal,xyz):cuda()
	fx1yz = getElements(imgOriginal,x1yz):cuda()
	fxy1z = getElements(imgOriginal,xy1z):cuda()
	fxyz1 = getElements(imgOriginal,xyz1):cuda()
	fx1y1z = getElements(imgOriginal,x1y1z):cuda()
	fx1yz1 = getElements(imgOriginal,x1yz1):cuda()
	fxy1z1 = getElements(imgOriginal,xy1z1):cuda()
	fx1y1z1 = getElements(imgOriginal,x1y1z1):cuda()


	function imgInterpolate()  
		Wfxyz =	  torch.cmul(i1,j1):cmul(k1)
		Wfx1yz =  torch.cmul(i,j1):cmul(k1)
		Wfxy1z =  torch.cmul(i1,j):cmul(k1)
		Wfxyz1 =  torch.cmul(i1,j1):cmul(k)
		Wfx1y1z = torch.cmul(i,j):cmul(k1)
		Wfx1yz1 = torch.cmul(i,j1):cmul(k)
		Wfxy1z1 = torch.cmul(i1,j):cmul(k)
		Wfx1y1z1 =torch.cmul(i,j):cmul(k)
		--weightedSum = Wfxyz + Wfx1yz + Wfxy1z + Wfxyz1 + Wfx1y1z + Wfx1yz1 + Wfx1y1z + Wfxy1z1 + Wfx1y1z1
		weightedSum = torch.cmul(Wfxyz,fxyz) + torch.cmul(Wfx1yz,fx1yz) + 
			      torch.cmul(Wfxy1z,fxy1z) + torch.cmul(Wfxyz1,fxyz1) +
			      torch.cmul(Wfx1y1z,fx1y1z) + torch.cmul(Wfx1yz1,fx1yz1) +
			      torch.cmul(Wfxy1z1,fxy1z1) + torch.cmul(Wfx1y1z1,fx1y1z1)
		return weightedSum
	end


	imgInterpolate = imgInterpolate():reshape(xSize,ySize,zSize)

	--[[
	-- Else just return image localized at original point to save time
	imgInterpolate = imgOriginal:sub(imgObject.z - sliceSize_2, imgObject.z + sliceSize_2-1,
			 imgObject.y - sliceSize_2, imgObject.y + sliceSize_2-1, 
			 imgObject.x - sliceSize_2, imgObject.x + sliceSize_2-1)
			 ]]--

	-- Normalize between -1 +1 
	imgInterpolate = (imgInterpolate - imgInterpolate:min())/(imgInterpolate:max()-imgInterpolate:min())*2 -1

	return imgInterpolate
end

--Example
--[[
function eg3d(display)

	dofile("readCsv.lua")
	dofile("imageCandidates.lua")
	csv = csvToTable("CSVFILES/candidatesClass1.csv")

	angleMax = 0.8
	sliceSize = 64 
	clipMin = -1014 -- clip sizes determined from ipython nb
	clipMax = 500

	--Initialize displays
	if displayTrue==nil and display==1 then
		print("Initializing displays ==>")
		zoom = 0.5
		init = image.lena()
		imgOrigX = image.display{image=init, zoom=zoom, offscreen=false}
		imgSubZ = image.display{image=init, zoom=zoom, offscreen=false}
		imgSubY = image.display{image=init, zoom=zoom, offscreen=false}
		imgSubX = image.display{image=init, zoom=zoom, offscreen=false}
		imgInterpolateDisZ = image.display{image=init, zoom=zoom, offscreen=false}
		imgInterpolateDisY = image.display{image=init, zoom=zoom, offscreen=false}
		imgInterpolateDisX = image.display{image=init, zoom=zoom, offscreen=false}
		displayTrue = "Display initialized"
	end

	

	for i=1,#csv do
		timer = torch.Timer()
		observationNumber = torch.random(#csv)
		obs = Candidate:new(csv,observationNumber)

		for j = 1,10 do 
			--observationNumber = torch.random(nobs)
			imgInterpolated, imgSub = rotation3d(obs, angleMax, sliceSize, clipMin, clipMax)
			print('Time elapsed for interpolation : ' .. timer:time().real .. ' seconds')	
			timer:reset()
			
			if display == 1 then 
				image.display{image = imgOriginal[obs.z], win = imgOrigX}

				image.display{image = imgSub[1+sliceSize/2], win = imgSubZ}
				image.display{image = imgSub[{{},{1+sliceSize/2}}]:reshape(sliceSize,sliceSize), win = imgSubY}
				image.display{image = imgSub[{{},{},{1+sliceSize/2}}]:reshape(sliceSize,sliceSize), win = imgSubX}

				image.display{image = imgInterpolated[1+sliceSize/2], win = imgInterpolateDisZ}
				image.display{image = imgInterpolated[{{},{1+sliceSize/2}}]:reshape(sliceSize,sliceSize), win = imgInterpolateDisY}
				image.display{image = imgInterpolated[{{},{},{1+sliceSize/2}}]:reshape(sliceSize,sliceSize), win = imgInterpolateDisX}
			end
		end
	end
end
]]--



