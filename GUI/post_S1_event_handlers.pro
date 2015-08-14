PRO S1_AVERAGE_STOKES_IMAGES, event
  ; Collect information into a structure
  ; Grab the input directory from the top-level base UVALUE
  tlb_wid          = WIDGET_INFO(event.top, FIND_BY_UNAME='WID_BASE')
  groupProgBarWID  = WIDGET_INFO(event.top, FIND_BY_UNAME='GROUP_PROGRESS_BAR')
  imageProgBarWID  = WIDGET_INFO(event.top, FIND_BY_UNAME='IMAGE_PROGRESS_BAR')
  displayWindowWID = WIDGET_INFO(event.top, FIND_BY_UNAME='IMAGE_DISPLAY_WINDOW')
  WIDGET_CONTROL, tlb_wid, GET_UVALUE=groupStruc
  WIDGET_CONTROL, displayWindowWID, GET_VALUE=displayWindowIndex

  ; Grab the object name from the group structure
  object_name = groupStruc.objectName

 
  ; Begin by simplifying references to the input/output directories, etc...
  inDir   = groupStruc.analysis_dir + 'S11_Full_Field_Polarimetry' + PATH_SEP()
  outDir  = groupStruc.analysis_dir + 'S11B_Combined_Images' + PATH_SEP()
  IF ~FILE_TEST(outDir, /DIRECTORY) THEN FILE_MKDIR, outDir
  stokesPars  = ['I','U','Q']

  FOR i = 0, 2 DO BEGIN
    stokes = stokesPars[i]
    UPDATE_PROGRESSBAR, groupProgBarWID, /ERASE
    UPDATE_PROGRESSBAR, groupProgBarWID, (i+1)*(100E/3E), DISPLAY_MESSAGE = 'Stokes ' + stokesPars[i]

    IF (stokes EQ 'U') OR (stokes EQ 'Q') THEN BEGIN
      valueName    = "*_" + stokes + "_cor.fits"                      ;stokes value name
      sigmaName    = "*s" + stokes + "_cor.fits"                      ;stokes uncertainty name
      valueFiles   = FILE_SEARCH(inDir + valueName, COUNT = nValFiles);List of stokes value files
      sigmaFiles   = FILE_SEARCH(inDir + sigmaName, COUNT = nSigFiles);List of stokes uncertainty files
      sigma        = 1                                                ;flag for inverse variance weighting
    ENDIF ELSE BEGIN
      valueName  = "*Intensity.fits"
      valueFiles = FILE_SEARCH(inDir + valueName, COUNT = nValFiles)  ;List of intensity image files
      sigma      = 0                                                  ;Un-flag inverse variance weighting
    ENDELSE

    PRINT_TEXT2, event, "Generating combined header"
    
    ;****USE LOOP TO GO THROUGH ALL STOKES VARIABLES AND GENERATE A !!SINGLE!! HEADER****
    CREATE_COMBINED_HEADER, valueFiles, inDir, object_name, all_astr, combined_header
    
    ; Grab the astrometry from the newly created header
    EXTAST, combined_header, new_astr,  noparams
    new_naxis1 = new_astr.naxis[0]                                    ;store the new image size (add some padding... figure this out later)
    new_naxis2 = new_astr.naxis[1]
    new_crpix1 = new_astr.crpix[0]                                    ;store the new reference value
    new_crpix2 = new_astr.crpix[1]

    IF N_ELEMENTS(old_naxis1) GT 0 THEN BEGIN
      IF (new_naxis1 NE old_naxis1) OR (new_naxis2 NE old_naxis2) THEN BEGIN
        PRINT_TEXT2, event, 'These images do not have matching sizes. FIX THE CODE!'
        RETURN
      ENDIF
    ENDIF
    
    ;Create an image into which the combined data will be fed
    n_files   = N_ELEMENTS(valueFiles)                                ;Count the files
    stack_img = FLTARR(new_naxis1, new_naxis2, n_files)               ;store the images in massive arrays
    stack_sig = FLTARR(new_naxis1, new_naxis2, n_files)               ;store the uncertainties in massive arrays
    
    ;Find the x_offsets and y_offsets from the center image
    AD2XY, all_astr.crval[0], all_astr.crval[1], new_astr, mapX, mapY
;    x_offsets = ROUND(mapX - new_crpix1)
;    y_offsets = ROUND(mapY - new_crpix2)
;    

    

;    PRINT_TEXT2, event, "Stacking input images into 3D array at " + STRMID(SYSTIME(), 11, 8)
;    PRINT_TEXT2, event, "... Please be patient."
;    WAIT, 0.1
    
    ;Stack the images into a 3D array
    FOR j = 0, n_files - 1 DO BEGIN
      ;Read in the input image
      in_img  = READFITS(valueFiles[j], tmp_header, /SILENT)
      
      ;Find the boundaries to which the input image maps
;      lf_in = ROUND(new_crpix1 + x_offsets[j] - 0.5*all_astr[j].naxis[0])
;      rt_in = ROUND(new_crpix1 + x_offsets[j] + 0.5*all_astr[j].naxis[0])
;      bt_in = ROUND(new_crpix2 + y_offsets[j] - 0.5*all_astr[j].naxis[1])
;      tp_in = ROUND(new_crpix2 + y_offsets[j] + 0.5*all_astr[j].naxis[1])
      lf_in = ROUND(mapX[j] - (all_astr[j].crpix[0])) + 1
      rt_in = lf_in + all_astr[j].naxis[0]
      bt_in = ROUND(mapY[j] - (all_astr[j].crpix[1])) + 1
      tp_in = bt_in + all_astr[j].naxis[1]
      
      ;   PRINT, SIZE(stack_img, /dim)
      ;   print, lf_in, rt_in, bt_in, tp_in
      ;Fill in one layer of the stack
      stack_img[lf_in:rt_in - 1, bt_in:tp_in - 1, j] = in_img
      IF KEYWORD_SET(sigma) THEN BEGIN
        sig_im  = READFITS(sigmaFiles[j], /SILENT)
        stack_sig[lf_in:rt_in - 1, bt_in:tp_in - 1, j] = sig_im
      ENDIF
    ENDFOR
    
    PRINT_TEXT2, event, "Averaging Stokes " +  stokes + " started at " + STRMID(SYSTIME(), 11, 8)
    
    out_img     = FLTARR(new_naxis1, new_naxis2)
    out_sig     = FLTARR(new_naxis1, new_naxis2)
    FOR k = 0, new_naxis1 - 1 DO BEGIN
      FOR l = 0, new_naxis2 - 1 DO BEGIN
        IF KEYWORD_SET(sigma) THEN BEGIN
          ;Preliminary filter out +/- 1E6 values and zero values
          good_data = WHERE(ABS(stack_img[k,l,*]) NE 1E6 $
            AND stack_img[k,l,*] NE 0 $
            AND ABS(stack_sig[k,l,*]) NE 1E6 $
            AND stack_sig[k,l,*] NE 0 , count)
          IF count GT 1 THEN BEGIN
            ;Filter out > 3-sigma deviation values
            merit_values = MEDIAN_FILTERED_MEAN(REFORM(stack_img[k,l,good_data]))
            good_data    = good_data[WHERE((ABS(stack_img[k,l,good_data] - merit_values[0]) LT 3*merit_values[1]), count)]
            IF count GT 0 THEN BEGIN
              ;Finally weight an average and create a normalization map
              out_pix = TOTAL(stack_img[k,l,good_data]/(stack_sig[k,l,good_data])^2)
              sig_pix = TOTAL(1/(stack_sig[k,l,good_data])^2)
              ;Test if this is an acceptable value to inclue in the final data
              IF FINITE(out_pix) AND (out_pix NE 0) AND FINITE(sig_pix) THEN BEGIN
                out_img[k,l] = TOTAL(stack_img[k,l,good_data]/(stack_sig[k,l,good_data])^2)
                out_sig[k,l] = TOTAL(1/(stack_sig[k,l,good_data])^2)
              ENDIF
            ENDIF
          ENDIF
        ENDIF ELSE BEGIN
          ;Preliminary filter out +/- 1E6 values and zero values
          good_data = WHERE((ABS(stack_img[k,l,*]) NE 1E6) AND (stack_img[k,l,*] NE 0), count)
          IF count GT 1 THEN BEGIN
            ;Average the good data
            zz           = MEDIAN_FILTERED_MEAN(REFORM(stack_img[k,l,good_data]))
            out_img[k,l] = zz[0]
            out_sig[k,l] = zz[1]
          ENDIF
        ENDELSE
        IF ~FINITE(out_img[k,l]) OR ~FINITE(out_sig[k,l]) THEN STOP
      ENDFOR
      
      updatePercent = 100E*(k+1)/new_naxis1                           ;Update the progress bar
      UPDATE_PROGRESSBAR, imageProgBarWID, updatePercent, /PERCENTAGE
      WAIT, 0.01                                                       ;Wait for the display to update
      
      old_naxis1 = new_naxis1                                         ;Store the naxis values to check with the next image
      old_naxis2 = new_naxis2
    ENDFOR
    
    UPDATE_PROGRESSBAR, imageProgBarWID, 100E, /PERCENTAGE
    WAIT, 0.1

    PRINT_TEXT2, event, "Averaging Stokes " +  stokes + " finished at " + STRMID(SYSTIME(), 11, 8)
    
    ;Fill in empty data data in the sigma map and output images
    IF KEYWORD_SET(sigma) THEN BEGIN
      zero_in = ARRAY_INDICES(out_sig, WHERE(out_sig EQ 0))
      out_sig[zero_in[0,*],zero_in[1,*]] = -1E6
      out_img = out_img/out_sig
      out_img[zero_in[0,*],zero_in[1,*]] = -1E6
    ENDIF
    
    
    ;Write the final output images
    band         = STRTRIM(SXPAR(combined_header, 'BAND'), 2)
;    stokes       = STRTRIM(SXPAR(combined_header, 'STOKES'), 2)
    outValuePath = outDir + band + "band_"  + stokes + ".fits"        ;path for writing weighted average
    outSigmaPath = outDir + band + "band_s" + stokes + ".fits"        ;path for writing weighted uncertainty

    WRITEFITS, outValuePath, out_img, combined_header
    IF KEYWORD_SET(sigma) THEN WRITEFITS, outSigmaPath, SQRT(1/out_sig), combined_header
    IF ~KEYWORD_SET(sigma) THEN BEGIN
      WSET, displayWindowIndex
      SKY, out_img, skyMode, skySig
      TVIM, out_img, RANGE = skyMode + [-2,+10*SQRT(groupStruc.numGroups)]*skySig
    ENDIF
  ENDFOR

END


PRO S1_FINAL_ASTROMETRY, event

  tlb_wid          = WIDGET_INFO(event.top, FIND_BY_UNAME='WID_BASE')  ;Retrieve the TLB widget ID
  groupProgBarWID  = WIDGET_INFO(event.top, FIND_BY_UNAME='GROUP_PROGRESS_BAR')
  imageProgBarWID  = WIDGET_INFO(event.top, FIND_BY_UNAME='IMAGE_PROGRESS_BAR')
  displayWindowWID = WIDGET_INFO(event.top, FIND_BY_UNAME='IMAGE_DISPLAY_WINDOW')
  WIDGET_CONTROL, tlb_wid, GET_UVALUE=groupStruc
  WIDGET_CONTROL, displayWindowWID, GET_VALUE=displayWindowIndex
  
  inDir          = groupStruc.analysis_dir + 'S11B_Combined_Images' + PATH_SEP()
  intensity_file = inDir + '*I.fits'                                  ;Store search string for the intensity file
  intensity_file = FILE_SEARCH(intensity_file, COUNT=numFiles)        ;Explicitly search for the correct *.fits file
  numStars       = N_ELEMENTS(groupStruc.starInfo)                    ;Count the maximum number of possible astrometry stars
  
  UPDATE_PROGRESSBAR, groupProgBarWID, /ERASE                         ;Clear out any previous progress bar status
  UPDATE_PROGRESSBAR, imageProgBarWID, /ERASE
  
  astroImage = READFITS(intensity_file, astroHeader)                  ;Read in the image
  sz         = SIZE(astroImage, /DIMENSIONS)                          ;Get the image dimensions
  hist       = SXPAR(astroHeader, "HISTORY")                          ;Get the history info
  SXDELPAR, astroHeader,'HISTORY'                                     ;delete any previous history entries
  EXTAST, astroHeader, astr                                           ;Extract the initial astrometry
  AD2XY, groupStruc.starInfo.RAJ2000, groupStruc.starInfo.DEJ2000, $  ;Solve for initial guesses on star positions
    astr, xGuess, yGuess
    
  useStar = (xGuess GT 30) AND (xGuess LT (sz[0] - 31)) $           ;Only use stars more than 30 pixels from image edge
    AND (yGuess GT 30) AND (yGuess LT (sz[1] - 31))
  useInds = WHERE(useStar, numUse)                                  ;Get the indices of the usable stars
  
  IF numUse GT 0 THEN BEGIN
    astroStars = groupStruc.starInfo[useInds]                       ;Cull the 2MASS data
    xGuess     = xGuess[useInds]                                    ;Cull the list to only the on-image stars
    yGuess     = yGuess[useInds]
  ENDIF
  
  xStars    = xGuess                                                ;Alias the x-star positions for refinement
  yStars    = yGuess                                                ;Alias the y-star positions for refinement
  useStar   = BYTARR(numUse)                                        ;Reset the "useStar" to track which stars were well fit
  FWHMs     = FLTARR(numUse)                                        ;Initalize an array for storing star FWHMs
  failedFit = 0                                                     ;Set a counter for the number of failed Gaussian star fits
  FOR j = 0, numUse - 1 DO BEGIN
    ;Cut out a subarray for a more precise positioning
    xOff     = (xGuess[j] - 19) > 0
    xRt      = (xOff  + 40) < (sz[0] - 1)
    yOff     = (yGuess[j] - 19) > 0
    yTop     = (yOff + 40)  < (sz[1] - 1)
    subArray = astroImage[xOff:xRt, yOff:yTop]
    
    result   = GAUSS2DFIT(subArray, A, /TILT)                       ;Gaussian fit the star
    inArray  = (A[4] GT 5) AND (A[4] LT 34) $                       ;If the fit is located in the center of the array
      AND (A[5] GT 5) AND (A[5] LT 34)
    okShape  = (A[2] GT 0.8) AND (A[2] LT 5) $                      ;and if its gaussian width is reasonable (not a hot pixel)
      AND (A[3] GT 0.8) AND (A[3] LT 5)
      
    methodDifference = 0                                            ;Reset the method difference variable
    IF inArray AND okShape THEN BEGIN
      FWHMs[j] = SQRT(ABS(A[2]*A[3]))*2.355                         ;Compute the FWHM for this star
      GCNTRD, subArray, A[4], A[5], xcen, ycen,  FWHMs[j]           ;Centroid this star (using estimated FWHM)
      methodDifference = SQRT((xCen - A[4])^2 + (yCen - A[5])^2)    ;Compute difference between the two locating methods
      IF (methodDifference LE 1) $                                  ;If the two methods have a consensus,
        AND FINITE(methodDifference) THEN BEGIN                     ;then update the star positions
        xStars[j]  = xOff + xcen
        yStars[j]  = yOff + ycen
        useStar[j] = 1                                              ;Mark this star as one of the stars to use
        failedFit  = 0                                              ;If the fit was successful, then reset the failed fit counter
        ;          TVIM, subarray
        ;          OPLOT, [xcen], [ycen], PSYM=6, color=255L
        ;          stop
      ENDIF
    ENDIF
    IF ~inArray OR ~ okShape $                                      ;If any one of the tests failed,
      OR (methodDifference GT 1) OR ~FINITE(methodDifference) $     ;then increment the failedFit counter
      THEN failedFit++
    IF failedFit GE 2 THEN BREAK                                    ;If the "failed fit"
  ENDFOR
  
  useInds = WHERE(useStar, numUse)                                  ;Determine which stars were well fit
  IF numUse GT 0 THEN BEGIN
    astroStars = astroStars[useInds]                                ;Cull the 2MASS data
    xStars     = xStars[useInds]                                    ;Cull the list to only the well fit stars
    yStars     = yStars[useInds]
  ENDIF
  
  printString = STRING(numUse, FORMAT='("Successfully located ",I2," stars")')
  PRINT_TEXT2, event, printString
  
  ;Now that the star positions are known, update the astrometry
  IF numUse GE 6 THEN BEGIN                                       ;Begin least squares method of astrometry
    ;**** PERFORM LEAST SQUARES ASTROMETRY ****
    astr = JM_SOLVE_ASTRO(astroStars.RAJ2000, astroStars.DEJ2000, $
      xStars, yStars, NAXIS1 = sz[0], NAXIS2 = sz[1])
    crpix = [511, 512]
    XY2AD, crpix[0], crpix[1], astr, crval1, crval2
    astr.crpix = (crpix + 1)                                      ;FITS convention is offset 1 pixel from IDL
    astr.crval = [crval1, crval2]                                 ;Store the updated reference pixel values
    PUTAST, astroHeader, astr, EQUINOX = 2000                     ;Update the header with the new astrometry
  ENDIF ELSE IF numUse GE 3 THEN BEGIN                            ;Begin "averaging" method of astrometry
    ;**** PERFORM 3-5 STAR ASTROMETRY ****
    numTri = numUse*(numUse-1)*(numUse-2)/6
    big_cd = DBLARR(2,2,numTri)
    triCnt = 0                                                    ;Initalize a counter for looping through triangles
    FOR iStar = 0, numUse - 1 DO BEGIN                            ;Loop through all possible triangles
      FOR jStar = iStar+1, numUse - 1 DO BEGIN
        FOR kStar = jStar+1, numUse - 1 DO BEGIN
          these_stars = [iStar,jStar,kStar]                       ;Grab the indices of the stars in this triangle
          STARAST, astroStars[these_stars].RAJ2000, $             ;Sove astrometry using this triangle of stars
            astroStars[these_stars].DEJ2000, $
            xStars[these_stars], yStars[these_stars], $
            this_cd, PROJECTION = 'TAN'
          big_cd[*,*,triCnt] = this_cd                            ;Store the CD matrix
          triCnt++                                                ;Increment the triangle counter
        ENDFOR
      ENDFOR
    ENDFOR
    cd_matrix = DBLARR(2,2)                                       ;Initalize an array for mean CD matrix
    FOR iMat = 0, 1 DO BEGIN
      FOR jMat = 0, 1 DO BEGIN
        cd_matrix[iMat,jMat] = $                                  ;Compute the mean CD matrix
          (MEDIAN_FILTERED_MEAN(REFORM(big_cd[iMat,jMat, *])))[0]
      ENDFOR
    ENDFOR
    crpix      = [511, 512]                                       ;Define the center pixels
    centerDist = SQRT((xStars - crpix[0])^2 + $                   ;Compute star distances from the image center
      (yStars - crpix[1])^2)
    centerStar = WHERE(centerDist EQ MIN(centerDist))             ;Grab the star closest to the image center
    deltaX     = crpix[0] - xStars[centerStar]                    ;Compute pixel x-offset from center
    deltaY     = crpix[1] - yStars[centerStar]                    ;Compute pixel y-offset from center
    deltaAD    = REFORM(cd_matrix##[[deltaX],[deltaY]])           ;Compute (RA, Dec) offsets from center
    deltaAD[0] = $                                                ;Correct RA offset for distortion
      deltaAD[0]*COS(astroStars[centerStar].DEJ2000*!DTOR)
    ;      crval      = [astroStars[centerStar].RAJ2000, $        ;Re-compute the center value
    ;                    astroStars[centerStar].DEJ2000]
    MAKE_ASTR, astr, CD = cd_matrix, CRPIX = [xStars[centerStar], yStars[centerStar]], $ ;Create final astrometry structure
      CRVAL = [astroStars[centerStar].RAJ2000, astroStars[centerStar].DEJ2000], CTYPE = ['RA---TAN','DEC--TAN']
    XY2AD, crpix[0], crpix[1], astr, crval1, crval2               ;Recenter astrometry structure
    MAKE_ASTR, astr, CD = cd_matrix, CRPIX = (crpix+1), $         ;Create final astrometry structure
      CRVAL = [crval1, crval2], CTYPE = ['RA---TAN','DEC--TAN']
    PUTAST, astroHeader, astr, EQUINOX = 2000                     ;Store astrometry in header
  ENDIF ELSE IF numUse EQ 2 THEN BEGIN
    ;****PERFORM 2-STAR ASTROMETRY****
    yMaxInd     = WHERE(yStars EQ MAX(yStars), COMPLEMENT=yMinInd)
    dXpix       = xStars[yMaxInd] - xStars[yMinInd]               ;Compute dx vector
    dYpix       = yStars[yMaxInd] - yStars[yMinInd]               ;Compute dy vector
    dRA         = (astroStars[yMaxInd].RAJ2000 - astroStars[yMinInd].RAJ2000)*COS(MEAN(astroStars.DEJ2000)*!DTOR)
    dDec        = (astroStars[yMaxInd].DEJ2000 - astroStars[yMinInd].DEJ2000)
    deltaPix    = SQRT(dXpix^2 + dYpix^2)                         ;Compute the pixel separation
    deltaTheta  = SQRT(dRA^2 + dDec^2)                            ;Compute angular separation (deg)
    plate_scale = deltaTheta/deltaPix                             ;Compute the plate scale (deg/pix)
    rotAnglePix = ATAN(dYpix, dXpix)*!RADEG                       ;Compute rotation angle of the two stars in image coordinates
    rotAngleEQ  = 180 - ATAN(dDec,  dRA)*!RADEG                   ;Compute rotation angle of the two stars in equatorial coords.
    CDmat1      = [[-plate_scale, 0E         ], $
      [ 0E         , plate_scale]]
    relativeRot = (rotAngleEQ - rotAnglePix)*!DTOR
    rotMatrix   = [[COS(relativeRot), -SIN(relativeRot)], $
      [SIN(relativeRot),  COS(relativeRot)]]
    CDmat       = CDmat1##rotMatrix
    crpix       = [511, 512]                                      ;Define the center pixels
    centerDist  = SQRT((xStars - crpix[0])^2 + $                  ;Compute star distances from the image center
      (yStars - crpix[1])^2)
    centerStar  = WHERE(centerDist EQ MIN(centerDist))            ;Grab the star closest to the image center
    deltaX      = crpix[0] - xStars[centerStar]                   ;Compute pixel x-offset from center
    deltaY      = crpix[1] - yStars[centerStar]                   ;Compute pixel y-offset from center
    deltaAD     = REFORM(CDmat##[[deltaX],[deltaY]])              ;Compute (RA, Dec) offsets from center
    deltaAD[0]  = $                                               ;Correct RA offset for distortion
      deltaAD[0]*COS(astroStars[centerStar].DEJ2000*!DTOR)
    MAKE_ASTR, astr, CD = CDmat, CRPIX = [xStars[centerStar], yStars[centerStar]], $ ;Create final astrometry structure
      CRVAL = [astroStars[centerStar].RAJ2000, astroStars[centerStar].DEJ2000], CTYPE = ['RA---TAN','DEC--TAN']
    XY2AD, crpix[0], crpix[1], astr, crval1, crval2               ;Recenter astrometry structure
    MAKE_ASTR, astr, CD = CDmat, CRPIX = (crpix+1), $             ;Create final astrometry structure
      CRVAL = [crval1, crval2], CTYPE = ['RA---TAN','DEC--TAN']
    PUTAST, astroHeader, astr, EQUINOX = 2000
  ENDIF ELSE BEGIN
    ;****PERFORM 1-STAR ASTROMETRY*****
  ENDELSE

  ;Restore the history to the header
  n_old = N_ELEMENTS(hist)
  FOR j= 0, n_old - 1 DO BEGIN
    SXADDPAR, astroHeader, "HISTORY", hist[j]
  ENDFOR
  ;**********************************************************************************************  
  ;**********************ALSO UPDATE U AND Q IMAGES WITH THE SAME ASTROMETRY ********************
  ;**********************************************************************************************
  
  
  ;Compute plate scale and rotation angle
;  CD_det     = astr.cd[0,0]*astr.cd[1,1] - astr.cd[0,1]*astr.cd[1,0]  ;Compute the CD matrix determinant
;  IF CD_det LT 0 THEN sgn = -1 ELSE sgn = 1
;  plateScale = SQRT(ABS(astr.cd[0,0]*astr.cd[1,1]) $                  ;Compute the mean plate scale
;                  + ABS(astr.cd[0,1]*astr.cd[1,0]))
;  rot1       = ATAN(  sgn*astr.cd[0,1],  sgn*astr.cd[0,0] )           ;Compute the rotation angle of the x-axis
;  rot2       = ATAN( -astr.cd[1,0],  astr.cd[1,1] )                   ;Compute the rotating angle of the y-axis
;  rotAngle   = SQRT(ABS(rot1*rot2))*!RADEG                            ;Compute a geometric mean of the rotation angles

  GETROT, astr, rotAngle, cdelt
  plateScale = SQRT(ABS(cdelt[0]*cdelt[1]))*3600D
;  groupStruc.finalPlateScale = plateScale                             ;Update the group structure to include the final plate scale
;  UPDATE_GROUP_SUMMARY, event, groupStruc
  UPDATE_GROUP_SUMMARY, event, groupStruc, 'finalPlateScale', plateScale ;Update the group structure to include the final plate scale
  

  centRA_WID = WIDGET_INFO(event.top, $                               ;Retrieve the center RA text ID
    FIND_BY_UNAME='RA_TEXT')
  RAstring = STRING(SIXTY(astr.CRVAL[0]/15.0), FORMAT='(I2,":",I2,":",F4.1)')
  WIDGET_CONTROL, centRA_WID, SET_VALUE=RAstring                     ;Display central RA
  
  centDec_WID = WIDGET_INFO(event.top, $                              ;Retrieve the center Dec text ID
    FIND_BY_UNAME='DEC_TEXT')
  DecString = STRING(SIXTY(astr.CRVAL[1]), FORMAT = '(I+3,":",I2,":",F4.1)')
  WIDGET_CONTROL, centDec_WID, SET_VALUE=DecString                    ;Display central Dec
  
  pl_sc_WID = WIDGET_INFO(event.top, $                                ;Retrieve the plate scale text ID
    FIND_BY_UNAME='PLATE_SCALE')
  plateScale = STRING(plateScale, FORMAT='(D9.6)')
  WIDGET_CONTROL, pl_sc_WID, SET_VALUE=plateScale                     ;Display the plate scale
  
  rotAngleWID = WIDGET_INFO(event.top, $                              ;Retrieve the rotation angle text ID
    FIND_BY_UNAME='ROT_ANGLE')

  rotAngle = STRING(rotAngle, FORMAT='(F8.4)')
  WIDGET_CONTROL, rotAngleWID, SET_VALUE=rotAngle                     ;Display the rotation angle

  
  AD2XY, groupStruc.starInfo.RAJ2000, groupStruc.starInfo.DEJ2000, $
    astr, xStars, yStars
  
  WSET, displayWindowIndex
;  TVIM, astroImage
  OPLOT, xStars, yStars, PSYM=6, COLOR=RGB_TO_DECOMPOSED([0,255,0])   ;Overplot the inferred star locations
  ARROWS, astroHeader, 0.9, 0.75, /NORMAL                             ;Show the North-East compas as sanity check  
  WRITEFITS, intensity_file, astroImage, astroHeader                  ;Write the file to disk
  PRINT_TEXT2, event, 'Finished computing astrometry'
    
END

PRO S1_FINAL_PHOTOMETRY, event

  PRINT_TEXT2, event, "Photometry started..."
  ;Start by getting all the data we need to do the matching
  tlb_wid    = WIDGET_INFO(event.top, FIND_BY_UNAME='WID_BASE')       ;Retrieve the top-level base ID
  displayWID = WIDGET_INFO(event.top, FIND_BY_UNAME='IMAGE_DISPLAY_WINDOW')
  WIDGET_CONTROL, tlb_wid, GET_UVALUE=groupStruc                      ;Retrieve the top-level base ID
  WIDGET_CONTROL, displayWID, GET_VALUE=displayWindowIndex

  NIRbands     = ['J','H','Ks']                                       ;Possible NIR bands
  bandNumber   = WHERE(NIRbands EQ groupStruc.NIRband, count)         ;Look for a matching NIR band
  IF count EQ 0 THEN STOP                                             ;Check that a match was actually found
  testBand   = TAG_EXIST(groupStruc.starInfo, $                       ;Find the tag containing magnitudes for this band
    STRMID(groupStruc.NIRband,0,1) + 'MAG', INDEX = magTag)
  
  intensityFile = FILE_SEARCH(groupStruc.analysis_dir, $              ;Read in the intensity image
    + 'S11B_Combined_Images' + PATH_SEP() + '*I.fits', COUNT = nFiles)
  IF nFiles NE 1 THEN STOP ELSE intensityImg = READFITS(intensityFile, header, /SILENT)
  sz = SIZE(intensityImg, /DIMENSIONS)

;  apr      = 2.5*PSF_FWHM
;  skyradii = [1.5, 2.5]*apr
  phpadu   = 8.21                                                     ;This value can be found on Mimir website
  ronois   = 17.8                                                     ;(elec) This value is from Mimir website
;  ronois   = 3.1                                                   ;(ADU) This value is from GPIPS code "S4_PSF_fit"
  badpix   = [-300L, 6000L]


  EXTAST, header, astr, noparams                                      ;Extract image astrometry
  GETROT, astr, rotAngle, cdelt
  plateScale   = SQRT(ABS(cdelt[0]*cdelt[1]))*3600E
  photStarInds = WHERE(groupStruc.photStarFlags, numPhotStars)
  IF numPhotStars GT 0 THEN $
    photStars    = groupStruc.starInfo[photStarinds] $                ;Alias the selected photometry stars
    ELSE MESSAGE, 'No photometry stars found'

  AD2XY, photStars.RAJ2000, photStars.DEJ2000, $                      ;Convert 2MASS positions to (x,y) pixel coordinates
    astr, xStars, yStars
  
  ;**** REFINE STAR POSITIONS ****
  useStar   = BYTARR(numPhotStars)                                    ;Reset the "useStar" to track which stars were well fit
  FWHMs     = FLTARR(numPhotStars)                                    ;Initalize an array for storing star FWHMs
  failedFit = 0                                                       ;Set a counter for the number of failed Gaussian star fits
  FOR j = 0, numPhotStars - 1 DO BEGIN
    ;Cut out a subarray for a more precise positioning
    xOff     = (xStars[j] - 19) > 0
    xRt      = (xOff  + 40) < (sz[0] - 1)
    yOff     = (yStars[j] - 19) > 0
    yTop     = (yOff + 40)  < (sz[1] - 1)
    subArray = intensityImg[xOff:xRt, yOff:yTop]
    
    result   = GAUSS2DFIT(subArray, A, /TILT)                         ;Gaussian fit the star
    inArray  = (A[4] GT 5) AND (A[4] LT 34) $                         ;If the fit is located in the center of the array
      AND (A[5] GT 5) AND (A[5] LT 34)
    okShape  = (A[2] GT 0.8) AND (A[2] LT 5) $                        ;and if its gaussian width is reasonable (not a hot pixel)
      AND (A[3] GT 0.8) AND (A[3] LT 5)
      
    methodDifference = 0                                              ;Reset the method difference variable
    IF inArray AND okShape THEN BEGIN
      FWHMs[j] = SQRT(ABS(A[2]*A[3]))*2.355                           ;Compute the FWHM for this star
      GCNTRD, subArray, A[4], A[5], xcen, ycen,  FWHMs[j]             ;Centroid this star (using estimated FWHM)
      methodDifference = SQRT((xCen - A[4])^2 + (yCen - A[5])^2)      ;Compute difference between the two locating methods
      IF (methodDifference LE 1) $                                    ;If the two methods have a consensus,
        AND FINITE(methodDifference) THEN BEGIN                       ;then update the star positions
        xStars[j]  = xOff + xcen
        yStars[j]  = yOff + ycen
        useStar[j] = 1                                                ;Mark this star as one of the stars to use
        failedFit  = 0                                                ;If the fit was successful, then reset the failed fit counter
        ;          TVIM, subarray
        ;          OPLOT, [xcen], [ycen], PSYM=6, color=255L
        ;          stop
      ENDIF
    ENDIF
    IF ~inArray OR ~ okShape $                                        ;If any one of the tests failed,
      OR (methodDifference GT 1) OR ~FINITE(methodDifference) $       ;then increment the failedFit counter
      THEN failedFit++
    IF failedFit GE 2 THEN BREAK                                      ;If the "failed fit"
  ENDFOR
  
  useInds = WHERE(useStar, numUse)                                    ;Determine which stars were well fit
  IF numUse GT 0 THEN BEGIN
    photStars = photStars[useInds]                                    ;Cull the 2MASS data
    xStars     = xStars[useInds]                                      ;Cull the list to only the well fit stars
    yStars     = yStars[useInds]
  ENDIF
  
  

  ;**** FIND THE OPTIMUM APERTURE FOR EACH STAR ****
  starFWHM    = GET_FWHM(intensityImg, xStars, yStars, 3.0, badpix[1]);Estimate the star FWHM
  largestApr  = 6*starFWHM[0]                                         ;Set the largest aperture used for COG measurements
;  largestApr  = 8*starFWHM[0]                                         ;Set the largest aperture used for COG measurements
  skyradii    = [1.2, SQRT(4 + 1.2^2)]*largestApr                     ;Forces Npix(sky) = 4*Npix(star) (largest aperture)
  rCritical   = MAX(skyradii) + 3*starFWHM[0]                         ;Compute grouping radius
  PRINT_TEXT2, event, STRING(starFWHM, FORMAT = '("Stellar 2D-Gaussian profile: FWHM = ", F4.2, " +/- ", F4.2, " (pixels)")')

  ;*** GROUPING ALGORITHM IS OBVIOUSLY NOT CORRECT. ***
  ;*** SIMPLY LOOK FOR STARS WITHIN Rcritical of each star ***
  ;  GROUP, starsMimir.x, starsMimir.y, rCritical, groupID               ;Collect stars into overlaping groups
  
  ;**************** SHOULD I SUBTRACT NEARBY STARS???? THAT IS THE QUESTION..... ***********
  PRINT_TEXT2, event, 'Computing aperatures at which photometric S/N is greatest for each star'
  optimumAprs = GET_OPTIMUM_APERTURES(intensityImg, xStars, yStars, $
    starFWHM[0], skyradii);, PSFfile)

  ;**********************************************************************************
  ;************************************TEMPORARY FIX*********************************
  ;**********************************************************************************
  useInds     = WHERE(FINITE(optimumAprs))
  optimumAprs = optimumAprs[useInds]
  xStars      = xStars[useInds]
  yStars      = yStars[useInds]
  photStars   = photStars[useInds]

  smallestApr = 0.8*MIN(optimumAprs)
;  smallestApr = 0.6*MIN(optimumAprs)
  aprIncr     = (largestApr/smallestApr)^(1.0/11.0)
  COGapr      = smallestApr*aprIncr^FINDGEN(12)                       ;Generate a list of apertures for COG

  ;**** GENERATE A CURVE OF GROWTH
  PRINT_TEXT2, event, 'Generating a King model curve-of-growth'
  stop
  kingParams = GENERATE_COG(intensityImg, xStars, yStars, $
    COGapr, skyradii)

  PRINT_TEXT2, event, 'S(r;Ri,A,B,C,D) = B*M(r;A) + (1-B)*[C*G(r;Ri) + (1-C)*H(r;D*Ri)]'
  PRINT_TEXT2, event, ' '
  PRINT_TEXT2, event, 'Where'
  PRINT_TEXT2, event, 'M(r;A)    = [(A-1)/pi]*(1 + r^2)^(-A)          --- Moffat function'
  PRINT_TEXT2, event, 'G(r;Ri)   = [1/(2*pi*Ri^2)]*Exp[-r^2/(2*Ri^2)] --- Gaussian function'
  PRINT_TEXT2, event, 'H(r;D*Ri) = [1/(2*pi*(D*Ri)^2)]*Exp[-r/(D*Ri)] --- exponential function' 

  
  ;Use the "set_sig_figs" functon to display these number strings
  parameterNames   = ['Ri','A ','B ','C ','D ']
  parameterStrings = SIG_FIG_STRING(kingParams, [3,6,3,3,3])
  
  FOR i = 0, N_ELEMENTS(KingParams) - 1 DO BEGIN
    parameterString = parameterNames[i] + ' = ' + parameterStrings[i]
    PRINT_TEXT2, event, parameterString
  ENDFOR

  ;**** COMPUTE APERTURE CORRECTIONS USING THE CURVE OF GROWTH ****
  PRINT_TEXT2, event, 'Computing aperture corrections for each star'
  aprCorrections = GET_APERTURE_CORRECTION(kingParams, optimumAprs)

  ;  Use APER to estimate magnitudes and fluxes of all the Mimir stars in the image
  nPhotStars = N_ELEMENTS(xStars)
  instMags   = FLTARR(nPhotStars)
  FOR i = 0, nPhotStars - 1 DO BEGIN
    APER, intensityImg, xStars[i], yStars[i], $
      mag, errap, sky, skyerr, phpadu, optimumAprs[i], skyradii, badpix, /SILENT
    instMags[i] = mag + aprCorrections[i]
    ;APER, intensityImg, photMimir.x, photMimir.y, $
    ;  flux, errap, sky, skyerr, phpadu, apr, skyradii, badpix, /SILENT, /FLUX
  ENDFOR
  
  ;Use NSTAR to simultaneously fit all stars
  ;  starIDs = INDGEN(N_ELEMENTS(starsMimir))
  ;  NSTAR, intensityImg, starIDs, starsMimir.x, starsMimir.y, mags, $
  ;    sky, nGroup, phpadu, ronois, psfFile, DEBUG=0, errMag,  /SILENT
  
  magZP     = 25                                                      ;APER and NSTAR use 1ADU/sec = 25 mag
  magsMimir = instMags - magZP                                        ;Convert to instrumental magnitudes
  mags2MASS = photStars.(magTag)                                      ;Grab the matched 2MASS magnitudes
  delMags   = mags2MASS - magsMimir                                   ;Compute the magnitude differences
  delFlux   = 10.0^(-0.4*delMags)                                     ;Convert differences to flux
  MEANCLIP, delFlux, meanRelativeFlux, sigmaFlux, $                   ;Compute mean relative flux
    CLIPSIG=3.0
    
  delMag  = -2.5*ALOG10(meanRelativeFlux)                             ;Convert the mean relative flux to magnitude
  magImg  = intensityImg                                              ;Alias the intensity image
  darkPix = WHERE(intensityImg LT 1, numDark)
  IF numDark GT 0 THEN magImg[darkPix] = 1                            ;Set bottom threshold
  magImg = -2.5*ALOG10(magImg) + $                                    ;Compute magnitude/arcsec^2 image
    delMag + 2.5*ALOG10(plateScale^2)
  
  delMagStr = STRING(delMag, FORMAT='("Instrumental magnitude offset is ", F5.2)')
  PRINT_TEXT2, event, delMagStr

  magFile = groupStruc.analysis_dir + 'S11B_Combined_Images' $        ;Define path for save file
    + PATH_SEP() + 'mu.fits'
  WRITEFITS, magFile, magImg, header
  
  ;
  ;Band Lambda (µm)   Bandwidth (µm)  Fnu - 0 mag (Jy)  Flambda - 0 mag (W cm-2 µm-1)
  ;J  1.235 ± 0.006   0.162 ± 0.001   1594 ± 27.8       3.129E-13 ± 5.464E-15
  ;H  1.662 ± 0.009   0.251 ± 0.002   1024 ± 20.0       1.133E-13 ± 2.212E-15
  ;Ks 2.159 ± 0.011   0.262 ± 0.002   666.7 ± 12.6      4.283E-14 ± 8.053E-16
  ;
  
  ;            J       H      Ks
  lambda   = (([1.235, 1.662, 2.159]*1E-6)[bandNumber])[0]            ;Wavelength (conv. to meters)
  width    = (([0.162, 0.251, 0.262]*1E-6)[bandNumber])[0]            ;Band width (conv. to meters)
  Fnu0     = (([1594E, 1024E, 666.7])[bandNumber])[0]                 ;Zero-point flux (Jy)
  Flambda0 = (([31.29, 11.33, 4.283]*1E-14)[bandNumber])[0]           ;Zero-point flux (W cm-2 um-1)
  MJyImg   = Fnu0*10.0^(-0.4*(magImg - 2.5*ALOG10(plateScale^2))) * $ ;Convert mag/arcsec^2...
    ((!RADEG*3600E/plateScale)^2) / 1E6                                ;...into MJy/Sr
    
  MJyFile = groupStruc.analysis_dir + 'S11B_Combined_Images' $        ;Define path for save file
    + PATH_SEP() + 'MJy_Sr.fits'
  WRITEFITS, MJyFile, MJyImg, header
  
  
  ;*******************************************************************
  ;******** NOW THAT EVERYTHING HAS BEEN COMPUTED, *******************
  ;******** LET'S SHOW THE USER WHAT WE FOUND.     *******************
  ;*******************************************************************
  
  WSET, displayWindowIndex
  xOriginal = !X.MARGIN
  !X.MARGIN = xOriginal*0.75
;  yOriginal = !Y.MARGIN
;  !Y.MARGIN = yOriginal/2.0
  !P.MULTI  = [0,2,2]

  
  ;**** DELTA-RA AND DELTA-DEC HISTOGRAMS ****
  XY2AD, (xStars-1), (yStars-1), astr, starRAs, starDecs
  deltaRA    = (photStars.RAJ2000 - starRAs)*3600D                    ;Compute positional difference in arcsec
  deltaDec   = (photStars.DEJ2000 - starDecs)*3600D
  binSize    = 0.5
  numBinsRA  = 0
  numBinsDec = 0
  
  numStars = N_ELEMENTS(xStars)
  minBins  = numStars < 4                                             ;Require at least three bins
  WHILE (numBinsRA LT minBins) OR (numBinsDec LT minBins) DO BEGIN    ;Iterate bin size until enough bins found
    PLOTHIST, deltaRA, histRA, numRA, BIN=binSize, /NOPLOT
    PLOTHIST, deltaDec, histDec, numDec, BIN=binSize, /NOPLOT
    numBinsRA  = TOTAL(numRA GT 0)
    numBinsDec = TOTAL(numDec GT 0)
    binSize   /= 1.2                                                  ;Decrease bin size
  ENDWHILE
  binSize *=1.2                                                       ;Undo the last decrement

  histRA  = [MIN(histRA) - binSize, histRA, MAX(histRA) + binSize]    ;Add a null element on either end of the histograms
  numRA   = [0,numRA,0]
  histDec = [MIN(histDec) - binSize, histDec, MAX(histDec) + binSize] ;Add a null element on either end of the histograms
  numDec  = [0,numDec,0]

  
  PLOT, histRA, numRA, PSYM=10, $                                     ;Plot the RA and Dec histograms
    THICK = 2, XTITLE = 'D RA (arcesc)', YTITLE = 'Number'
  PLOT, histDec, numDec, PSYM=10, $
    THICK = 2, XTITLE = 'D Dec (arcsec)', YTITLE = 'Number'

  ;**** DELTA-MAG HISTOGRAM ****
  binSize    = 0.5
  numBinsMag = 0
  WHILE (numBinsMag LT 4) DO BEGIN
    PLOTHIST, (delMags - delMag), histMag, numMag, BIN=binSize, /NOPLOT
    numBinsMag = TOTAL(numMag GT 0)
    binSize  /= 1.2
  ENDWHILE
  binSize *=1.2                                                       ;Undo the last decrement
  
  histMag = [MIN(histMag) - binSize, histMag, MAX(histMag) + binSize] ;Add a null element on either end of the histograms
  numMag  = [0,numMag,0]
  
  PLOT, histMag, numMag, PSYM=10, $                                 ;Plot the magnitude histogram
    THICK = 2, XTITLE = 'D mag', YTITLE = 'Number'

  ;**** CURVE OF GROWTH **** 
  ;Disambiguate the King mmodel parameters
  Ri = kingParams[0]                                                  ;Gaussian standard-deviation width
  A  = kingParams[1]                                                  ;Moffat denominator exponent
  B  = kingParams[2]                                                  ;Weighting for the Moffat component
  C  = kingParams[3]                                                  ;Weighting for the Gaussian (and exponential component)
  D  = kingParams[4]                                                  ;Scale radius for the exponential component
  
  nModelApr  = 50                                                     ;Set the number of model apertures to use
  Napr       = N_ELEMENTS(COGapr)                                     ;Count the number of actual apertures used
  modelApr   = MIN(COGapr)  $                                         ;Compute the model apertures to use
               + 1.2*(MAX(COGapr) - MIN(COGapr))*FINDGEN(nModelApr)/(nModelApr - 1)
  
  
  ;************* THIS PART SHOULD BE DONE INSIDE "GENERATE_COG"
  ;************* AND RETURNED AS A NAMED VARIABLE
  APER, intensityImg, xStars, yStars, $                               ;Compute the magnitudes at the COG apertures
    mags, errap, sky, skyerr, phpadu, COGapr, skyradii, badpix, /SILENT  


  ;Compute the mean delta-magnitude at that incremental aperture
  delMags = FLTARR(Napr-1)
  err     = FLTARR(Napr-1)
  FOR i = 0, Napr - 2 DO BEGIN
    MEANCLIP, (mags[i+1,*] - mags[i,*]), meanDelMag, sigMag, CLIPSIG=3.0
    delMags[i] = meanDelMag
    err[i]     = sigMag
  ENDFOR
  
  ;Compute the expected delta-magnitude at that incremental aperture
  ;using the fitted King model parameters
  delMags1   = 0.0*modelApr
  FOR i = 0, nModelApr - 2 DO BEGIN
    numerLimits = [0,modelApr[i+1]]
    denomLimits = [0,modelApr[i]]
    numerator   = INTEGRATED_KING_MODEL(kingParams, numerLimits)
    denominator = INTEGRATED_KING_MODEL(kingParams, denomLimits)
    kingCOG     = -2.5*ALOG10(numerator/denominator)
    delMags1[i] = kingCOG
  ENDFOR
  
  ;******* I'VE SET THE UNITS TO BE Dmag/Dpixel **********

  xCOGdata = 0.5*(COGapr[1:Napr-1] + COGapr[0:Napr-2])
  yCOGdata = delMags/(COGapr[1:Napr-1] - COGapr[0:Napr-2])
;  PLOT, COGapr[0:Napr-2], delMags, /NODATA, YRANGE = [-0.8, +0.2], $
;    XTITLE = "Aperture (pixels)", $
;    YTITLE = "D mag/D aperture (mag/pixel)"
  PLOT, xCOGdata, yCOGdata, /NODATA, $
    XTITLE = "Aperture (pixels)", $
    YTITLE = "D mag/D aperture (mag/pixel)"
  
  OPLOT, 0.5*(modelApr[1:nModelApr-1] + modelApr[0:nModelApr-2]), $
    delMags1/(modelApr[1:nModelApr-1] - modelApr[0:nModelApr-2]), $
    THICK = 2, COLOR=RGB_TO_DECOMPOSED([0,255,0])
  
  OPLOT, xCOGdata, yCOGdata, PSYM = 4, THICK = 2
  ERRPLOT, xCOGdata, yCOGdata + err, yCOGdata - err, THICK = 2 
;  OPLOTERR, 0.5*(COGapr[1:Napr-1] + COGapr[0:Napr-2]), delMags/(COGapr[1:Napr-1] - COGapr[0:Napr-2]), err, 4

  !P.MULTI  = 0
  !X.MARGIN = xOriginal
;  !Y.MARGIN = yOriginal
  
END