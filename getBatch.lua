function getBatch(data,batchSize,xBatchTensor,yBatchTensor,sliceSize,clipMin,clipMax,angleMax,scalingFactor,test,para)

	-- For each image file in a batch. 1/ Load it 2/ Rotate it /3 Place it in batch tensor

	for i=1, batchSize do
		if data.finishedScan == true then
			data:getNewScan()
		else
			data:getNextCandidate()
		end

		if #para>1 then 
			--x = {}
			for iScaling=1, #para do
			   xBatchTensor[iScaling][i] = rotation3d(data, angleMax, sliceSize, clipMin, clipMax, para[iScaling] , test):reshape(1,sliceSize,sliceSize,sliceSize)

			end
		else
			x = rotation3d(data, angleMax, sliceSize, clipMin, clipMax, scalingFactor, test):reshape(1,sliceSize,sliceSize,sliceSize)

		end
		local y = data.Class
--		xBatchTensor[i] = x 
		yBatchTensor[i] = y 
	end


	collectgarbage()

end

